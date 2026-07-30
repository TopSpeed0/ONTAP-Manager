<#
.SYNOPSIS
    Pure, cluster-free functions for ONTAP snapshot inventory, parsing, and ranking.

.DESCRIPTION
    Every function here is deterministic and takes its input as plain strings or objects,
    so the whole collection-and-reporting path can be exercised offline with fixtures
    (see scripts\testing\Test-SnapshotComparisonScripts.ps1).

    The cluster-facing driver is scripts\snapshots\Get-SnapshotComparison.ps1 — it only
    supplies SSH output to these functions.

    READ-ONLY BY CONSTRUCTION: the only ONTAP command this module produces is
    `vol snapshot show`. Get-SnapshotInventoryCommand refuses to emit anything else.

.NOTES
    The wire format handled by ConvertFrom-OntapSnapshotCsv was captured from a live
    ONTAP 9 cluster on 2026-07-30 with:

        set diagnostic -confirmations off -showseparator ','; row 0
        vol snapshot show -fields vserver,volume,snapshot,create-time,size,snapmirror-label,state,busy,owners

    Two properties of that output drive the design:

    1. ONTAP returns the fields in ITS OWN order, not the order requested. The capture
       above came back as vserver,volume,snapshot,create-time,busy,owners,size,
       snapmirror-label,state. Parsing therefore MUST be driven by the field-name header
       line — positional parsing silently swaps size and busy.
    2. The login/banner block before the header is NOT a fixed number of lines (8 lines
       in one capture, 6 in another). Anything that skips a fixed line count either eats
       the first data row or accepts the display-name row as data.
#>

Set-StrictMode -Version Latest

# ONTAP field names accepted by `vol snapshot show -fields`, taken verbatim from
# `vol snapshot show -fields ?` on a live ONTAP 9 cluster (2026-07-30). Anything not in
# this list is not a real field and must not be requested.
$script:OntapSnapshotFields = @(
    'vserver', 'volume', 'snapshot', 'dsid', 'msid', 'create-time', 'busy', 'owners',
    'size', 'blocks', 'usedblocks', 'cpcount', 'comment', 'fs-version', 'fs-block-format',
    'physical-snap-id', 'logical-snap-id', 'record-owner', 'tags', 'instance-uuid',
    'version-uuid', 'is-7-mode', 'snapmirror-label', 'state', 'is-constituent', 'node',
    'afs-used', 'compress-savings', 'dedup-savings', 'vbn0-savings', 'reserved-size',
    'logical-used', 'performance-metadata', 'inofile-version', 'expiry-time',
    'compression-type', 'snaplock-expiry-time', 'application-io-size',
    'is-qtree-caching-enabled', 'compression-algorithm', 'is-convert-recovery',
    'snaplock-snapshot-expired', 'seconds-until-snaplock-snapshot-expiry'
)

# The fields this tool collects. Every one is in $script:OntapSnapshotFields above.
$script:DefaultSnapshotFields = @(
    'vserver', 'volume', 'snapshot', 'create-time', 'size',
    'snapmirror-label', 'state', 'busy', 'owners'
)

function Get-OntapSnapshotFieldCatalog {
    <#
    .SYNOPSIS
        The ONTAP-reported valid field list for `vol snapshot show`.
    #>
    [CmdletBinding()]
    param()
    @($script:OntapSnapshotFields)
}

function Get-SnapshotInventoryCommand {
    <#
    .SYNOPSIS
        Builds the read-only ONTAP CLI command used to inventory snapshots.

    .DESCRIPTION
        Single source of truth for the command sent to a cluster. Validates every
        requested field against the ONTAP-reported catalog so a typo becomes an error
        here rather than an empty report later.

        `row 0` is required: with a row limit ONTAP emits an interactive
        "Press <space> to page down" prompt and truncates the output.

    .EXAMPLE
        Get-SnapshotInventoryCommand
    #>
    [CmdletBinding()]
    param(
        [string[]]$Fields = $script:DefaultSnapshotFields,
        [string]$Volume,
        [string]$Svm
    )

    if (-not $Fields -or $Fields.Count -eq 0) {
        throw "Get-SnapshotInventoryCommand: at least one field is required."
    }

    $bad = @($Fields | Where-Object { $_ -notin $script:OntapSnapshotFields })
    if ($bad.Count -gt 0) {
        throw ("Get-SnapshotInventoryCommand: not valid 'vol snapshot show' fields: {0}. " +
               "Valid fields come from 'vol snapshot show -fields ?'." -f ($bad -join ', '))
    }

    $cmd = "set diagnostic -confirmations off -showseparator ','; row 0; " +
           "vol snapshot show -fields $($Fields -join ',')"
    if ($Svm)    { $cmd += " -vserver $Svm" }
    if ($Volume) { $cmd += " -volume $Volume" }

    # Read-only guard. This module must never be the thing that emits a mutating verb.
    foreach ($verb in @('delete', 'create', 'modify', 'rename', 'restore', 'destroy',
                        'offline', 'online', 'autodelete', 'partial-restore')) {
        if ($cmd -match "snapshot\s+$verb\b") {
            throw "Get-SnapshotInventoryCommand: refusing to emit a mutating command ('$verb')."
        }
    }
    $cmd
}

function Convert-OntapSize {
    <#
    .SYNOPSIS
        Converts an ONTAP size string ("2.26GB", "156KB", "-") to bytes.

    .DESCRIPTION
        Returns $null — never 0 — when the value is absent or unparseable. A failed size
        read must not masquerade as a real zero-byte snapshot: 0 sorts as "smallest" and
        would quietly drop the record out of any largest-N ranking while still looking
        like a successful measurement.

    .EXAMPLE
        Convert-OntapSize '2.26GB'    # 2426656522
    #>
    [CmdletBinding()]
    [OutputType([System.Nullable[System.Int64]])]
    param([AllowNull()][string]$Size)

    if ([string]::IsNullOrWhiteSpace($Size)) { return $null }
    $s = $Size.Trim().Trim('"').Trim()
    if ($s -eq '-' -or $s -eq '') { return $null }

    $units = @{ 'B' = 1D; 'KB' = 1024D; 'MB' = 1048576D; 'GB' = 1073741824D
                'TB' = 1099511627776D; 'PB' = 1125899906842624D }

    if ($s -match '^\s*(?<num>[-+]?\d+(?:\.\d+)?)\s*(?<unit>PB|TB|GB|MB|KB|B)?\s*$') {
        $num  = [decimal]$Matches['num']
        # An optional group that did not participate is absent from $Matches, not empty.
        $unit = if ($Matches.ContainsKey('unit') -and $Matches['unit']) {
                    ([string]$Matches['unit']).ToUpperInvariant()
                } else { 'B' }
        try   { return [int64][math]::Round($num * $units[$unit]) }
        catch { return $null }
    }
    return $null
}

function Format-SnapshotBytes {
    <#
    .SYNOPSIS
        Formats a byte count for reports. Returns '' for $null so a blank cell stays blank.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][System.Nullable[System.Int64]]$Bytes)

    if ($null -eq $Bytes) { return '' }
    $b = [double]$Bytes
    foreach ($u in @(@{N = 'PB'; D = 1125899906842624D }, @{N = 'TB'; D = 1099511627776D },
                     @{N = 'GB'; D = 1073741824D }, @{N = 'MB'; D = 1048576D },
                     @{N = 'KB'; D = 1024D })) {
        if ([math]::Abs($b) -ge $u.D) {
            return ('{0:N2} {1}' -f ($b / $u.D), $u.N)
        }
    }
    '{0} B' -f [int64]$Bytes
}

function Convert-OntapSnapshotTime {
    <#
    .SYNOPSIS
        Parses an ONTAP snapshot creation time into a DateTime.

    .DESCRIPTION
        ONTAP's `create-time` column is a UNIX ctime-style string in CLUSTER-LOCAL time
        with no offset, e.g. "Wed Jul 29 00:00:18 2026". A single-digit day is padded with
        a second space ("Wed Jul  9 ..."), so whitespace is normalised before parsing.

        Returns $null when the value is absent or unparseable — the caller reports it as an
        unknown age rather than inventing one.

    .EXAMPLE
        Convert-OntapSnapshotTime 'Wed Jul 29 00:00:18 2026'
    #>
    [CmdletBinding()]
    [OutputType([System.Nullable[System.DateTime]])]
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $t = $Text.Trim().Trim('"').Trim()
    if ($t -eq '-' -or $t -eq '') { return $null }
    $t = ($t -replace '\s+', ' ')

    $ci = [System.Globalization.CultureInfo]::InvariantCulture
    $formats = @(
        'ddd MMM d HH:mm:ss yyyy',      # ONTAP CLI create-time
        'ddd MMM d HH:mm:ss yyyy zzz',
        'M/d/yyyy HH:mm:ss',
        'yyyy-MM-dd HH:mm:ss',
        'yyyy-MM-ddTHH:mm:ss',
        'yyyy-MM-ddTHH:mm:ssK'
    )
    $parsed = [datetime]::MinValue
    # The [string[]] cast is required: handing TryParseExact an object[] silently binds a
    # different overload and every timestamp comes back unparsed.
    if ([datetime]::TryParseExact($t, [string[]]$formats, $ci,
            [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        return $parsed
    }
    # ONTAP epoch seconds (some ZAPI/REST paths hand back a raw integer).
    if ($t -match '^\d{9,11}$') {
        try { return [datetimeoffset]::FromUnixTimeSeconds([int64]$t).LocalDateTime } catch { return $null }
    }
    if ([datetime]::TryParse($t, $ci, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        return $parsed
    }
    $null
}

function ConvertFrom-OntapSnapshotCsv {
    <#
    .SYNOPSIS
        Parses raw `vol snapshot show` SSH output into field-name-keyed objects.

    .DESCRIPTION
        Header-driven and banner-tolerant:
          * finds the ONTAP field-name line by matching it against the requested/known
            field catalog — not by counting banner lines
          * skips the human display-name line that follows it
          * maps values BY FIELD NAME, so ONTAP reordering the columns cannot swap them
          * unwraps ONTAP's `','` separator and per-value double quotes
          * turns '-' into $null
          * a row whose column count does not match the header is reported in
            -ParseErrors instead of being mis-mapped

    .OUTPUTS
        PSCustomObject per snapshot, with one property per ONTAP field name.

    .EXAMPLE
        ConvertFrom-OntapSnapshotCsv -Lines $raw -ParseErrors ([ref]$errs)
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()]
        [string[]]$Lines,

        # Receives [PSCustomObject]@{ Line; Reason } for every line that could not be used.
        [ref]$ParseErrors
    )

    $errors = [System.Collections.Generic.List[object]]::new()
    $out    = [System.Collections.Generic.List[object]]::new()

    if (-not $Lines -or $Lines.Count -eq 0) {
        if ($ParseErrors) { $ParseErrors.Value = $errors.ToArray() }
        return @()
    }

    # ONTAP echoes the separator between values, so a data/header line looks like
    #   value','value','value','
    $sep = "','"

    # NOTE: no unary comma on the return. `, @(...)` emits the array as a SINGLE object, so
    # a caller writing @(Split-OntapLine ...) gets an array-of-array of Count 1 and every
    # row is rejected for a column-count mismatch.
    function Split-OntapLine {
        param([string]$Line)
        $l = $Line
        if ($l.EndsWith($sep)) { $l = $l.Substring(0, $l.Length - $sep.Length) }
        $l = $l -replace "'\s*$", ''
        @($l -split [regex]::Escape($sep))
    }

    function Clear-OntapValue {
        param([AllowNull()][string]$Value)
        if ($null -eq $Value) { return $null }
        $v = $Value.Trim()
        if ($v.Length -ge 2 -and $v.StartsWith('"') -and $v.EndsWith('"')) {
            $v = $v.Substring(1, $v.Length - 2)
        }
        $v = $v.Trim()
        if ($v -eq '' -or $v -eq '-') { return $null }
        $v
    }

    $noise = @(
        'Last login',
        'entries were displayed',
        'There are no entries matching',
        'Press <space> to page down',
        '^\s*\(rows?\)\s*$',
        '^\s*\(vol',
        '^\s*$',
        '^Warning:',
        '^\s*WARNING'
    )

    $headerIdx = -1
    $header    = $null

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = [string]$Lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notlike "*$sep*") { continue }

        $tokens = @(Split-OntapLine -Line $line | ForEach-Object { $_.Trim() })
        if ($tokens.Count -eq 0) { continue }

        # The field-name line is the one whose tokens are ALL real ONTAP field names.
        $allKnown = $true
        foreach ($t in $tokens) {
            if ($t -notin $script:OntapSnapshotFields) { $allKnown = $false; break }
        }
        if ($allKnown) {
            $headerIdx = $i
            $header    = $tokens
            break
        }
    }

    if ($headerIdx -lt 0) {
        foreach ($line in $Lines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $skip = $false
            foreach ($n in $noise) { if ($line -match $n) { $skip = $true; break } }
            if ($skip) { continue }
            $errors.Add([PSCustomObject]@{ Line = $line; Reason = 'no field-name header line found in output' })
        }
        if ($ParseErrors) { $ParseErrors.Value = $errors.ToArray() }
        return @()
    }

    # The line straight after the field names is ONTAP's display-name row ("Snapshot Size").
    $start = $headerIdx + 1
    if ($start -lt $Lines.Count) {
        $next = [string]$Lines[$start]
        if ($next -like "*$sep*") {
            $nextTokens = @(Split-OntapLine -Line $next | ForEach-Object { $_.Trim() })
            $looksLikeDisplayRow = $false
            if ($nextTokens.Count -eq $header.Count) {
                # Display names are Title Case / contain spaces; field names never do.
                $titleish = @($nextTokens | Where-Object { $_ -match '^[A-Z]' -or $_ -match '\s' }).Count
                if ($titleish -ge [math]::Ceiling($header.Count / 2)) { $looksLikeDisplayRow = $true }
            }
            if ($looksLikeDisplayRow) { $start++ }
        }
    }

    for ($i = $start; $i -lt $Lines.Count; $i++) {
        $line = [string]$Lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        $skip = $false
        foreach ($n in $noise) { if ($line -match $n) { $skip = $true; break } }
        if ($skip) { continue }

        if ($line -notlike "*$sep*") {
            $errors.Add([PSCustomObject]@{ Line = $line; Reason = 'not a separated data row' })
            continue
        }

        $tokens = @(Split-OntapLine -Line $line)
        if ($tokens.Count -ne $header.Count) {
            $errors.Add([PSCustomObject]@{
                Line   = $line
                Reason = "column count $($tokens.Count) does not match header count $($header.Count)"
            })
            continue
        }

        $row = [ordered]@{}
        for ($c = 0; $c -lt $header.Count; $c++) {
            $row[$header[$c]] = Clear-OntapValue -Value $tokens[$c]
        }
        $out.Add([PSCustomObject]$row)
    }

    if ($ParseErrors) { $ParseErrors.Value = $errors.ToArray() }
    @($out.ToArray())
}

function ConvertTo-SnapshotRecord {
    <#
    .SYNOPSIS
        Normalises a parsed ONTAP row into the canonical snapshot record used by reports.

    .DESCRIPTION
        -Now is an explicit parameter so age calculation is deterministic in tests.
        A snapshot with no parseable create-time gets AgeDays = $null, never 0.

    .EXAMPLE
        $rows | ConvertTo-SnapshotRecord -Cluster $alias -ClusterName $clusterName -Now $now
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)] $Row,
        [Parameter(Mandatory)][string]$Cluster,
        [string]$ClusterName,
        [datetime]$Now = (Get-Date)
    )
    begin {
        if (-not $ClusterName) { $ClusterName = $Cluster }
    }
    process {
        $get = {
            param($name)
            if ($Row.PSObject.Properties.Name -contains $name) { $Row.$name } else { $null }
        }

        $sizeText   = & $get 'size'
        $sizeBytes  = Convert-OntapSize $sizeText
        $createText = & $get 'create-time'
        $created    = Convert-OntapSnapshotTime $createText

        $ageDays = $null
        if ($null -ne $created) { $ageDays = [math]::Round(($Now - $created).TotalDays, 2) }

        $busyText = & $get 'busy'
        $busy     = $null
        if ($busyText) {
            if ($busyText -match '^(?i)true$')  { $busy = $true }
            if ($busyText -match '^(?i)false$') { $busy = $false }
        }

        $owners = & $get 'owners'
        $lockReasons = @()
        if ($busy -eq $true) { $lockReasons += 'busy' }
        if ($owners)         { $lockReasons += "owners=$owners" }

        [PSCustomObject]@{
            Cluster         = $Cluster
            ClusterName     = $ClusterName
            Svm             = & $get 'vserver'
            Volume          = & $get 'volume'
            Snapshot        = & $get 'snapshot'
            CreateTimeText  = $createText
            CreateTime      = $created
            AgeDays         = $ageDays
            SizeText        = $sizeText
            SizeBytes       = $sizeBytes
            SizeDisplay     = Format-SnapshotBytes $sizeBytes
            SnapmirrorLabel = & $get 'snapmirror-label'
            State           = & $get 'state'
            Busy            = $busy
            Owners          = $owners
            Locked          = ($lockReasons.Count -gt 0)
            LockReason      = if ($lockReasons.Count) { $lockReasons -join '; ' } else { $null }
        }
    }
}

function Get-SnapshotReportSet {
    <#
    .SYNOPSIS
        Ranks and buckets snapshot records — the whole reporting decision layer, pure.

    .DESCRIPTION
        Produces, from one record set:
          All              every record, cluster/SVM/volume/snapshot sorted
          Oldest           top-N by age (records with an unknown create-time excluded)
          Largest          top-N by size (records with an unknown size excluded)
          OldCandidates    AgeDays >= AgeDays threshold
          LargeCandidates  SizeBytes >= LargeThresholdBytes
          ClusterSummary   per-cluster counts, total bytes, oldest/largest
          Unknown          records missing a create-time or a size
          Stats            counts used for the console summary

        Records with a missing measurement are never silently treated as 0 bytes or
        0 days old — they are excluded from rankings and surfaced in Unknown so a failed
        read cannot read as "small and new".

    .EXAMPLE
        Get-SnapshotReportSet -Records $recs -AgeDays 90 -LargeThresholdBytes 100GB -Now $now
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$Records,
        [double]$AgeDays = 90,
        [int64]$LargeThresholdBytes = 107374182400,   # 100 GiB
        [int]$TopOldest = 50,
        [int]$TopLargest = 50,
        [datetime]$Now = (Get-Date)
    )

    $recs = @($Records | Where-Object { $null -ne $_ })

    $all = @($recs | Sort-Object Cluster, Svm, Volume, Snapshot)

    $dated  = @($recs | Where-Object { $null -ne $_.CreateTime })
    $sized  = @($recs | Where-Object { $null -ne $_.SizeBytes })
    $noDate = @($recs | Where-Object { $null -eq $_.CreateTime })
    $noSize = @($recs | Where-Object { $null -eq $_.SizeBytes })

    $oldest = @($dated | Sort-Object CreateTime |
        Select-Object -First ([math]::Max(0, $TopOldest)))
    $largest = @($sized | Sort-Object -Property SizeBytes -Descending |
        Select-Object -First ([math]::Max(0, $TopLargest)))

    $oldCandidates   = @($dated | Where-Object { $_.AgeDays -ge $AgeDays } | Sort-Object CreateTime)
    $largeCandidates = @($sized | Where-Object { $_.SizeBytes -ge $LargeThresholdBytes } |
        Sort-Object -Property SizeBytes -Descending)

    $rank = 0
    $oldest = @($oldest | ForEach-Object {
        $rank++
        $_ | Select-Object @{N = 'Rank'; E = { $rank } }, *
    })
    $rank = 0
    $largest = @($largest | ForEach-Object {
        $rank++
        $_ | Select-Object @{N = 'Rank'; E = { $rank } }, *
    })

    $summary = @(
        $recs | Group-Object Cluster | Sort-Object Name | ForEach-Object {
            $g   = @($_.Group)
            $gs  = @($g | Where-Object { $null -ne $_.SizeBytes })
            $gd  = @($g | Where-Object { $null -ne $_.CreateTime })
            $tot = if ($gs.Count) { [int64](($gs | Measure-Object -Property SizeBytes -Sum).Sum) } else { $null }
            $oldestRec  = if ($gd.Count) { ($gd | Sort-Object CreateTime | Select-Object -First 1) } else { $null }
            $largestRec = if ($gs.Count) { ($gs | Sort-Object -Property SizeBytes -Descending | Select-Object -First 1) } else { $null }
            [PSCustomObject]@{
                Cluster            = $_.Name
                Snapshots          = $g.Count
                Volumes            = @($g | Select-Object -ExpandProperty Volume -Unique).Count
                Svms               = @($g | Select-Object -ExpandProperty Svm -Unique).Count
                TotalBytes         = $tot
                TotalSize          = Format-SnapshotBytes $tot
                SizeUnknown        = @($g | Where-Object { $null -eq $_.SizeBytes }).Count
                DateUnknown        = @($g | Where-Object { $null -eq $_.CreateTime }).Count
                Locked             = @($g | Where-Object { $_.Locked }).Count
                OldestCreateTime   = if ($oldestRec)  { $oldestRec.CreateTime }  else { $null }
                OldestAgeDays      = if ($oldestRec)  { $oldestRec.AgeDays }     else { $null }
                OldestSnapshot     = if ($oldestRec)  { "$($oldestRec.Svm):$($oldestRec.Volume):$($oldestRec.Snapshot)" } else { $null }
                LargestSize        = if ($largestRec) { $largestRec.SizeDisplay } else { '' }
                LargestSnapshot    = if ($largestRec) { "$($largestRec.Svm):$($largestRec.Volume):$($largestRec.Snapshot)" } else { $null }
                OldCandidates      = @($gd | Where-Object { $_.AgeDays -ge $AgeDays }).Count
                LargeCandidates    = @($gs | Where-Object { $_.SizeBytes -ge $LargeThresholdBytes }).Count
            }
        }
    )

    $unknown = @(
        @($noDate + $noSize) | Sort-Object Cluster, Svm, Volume, Snapshot -Unique | ForEach-Object {
            $why = @()
            if ($null -eq $_.CreateTime) { $why += 'create-time unparsed' }
            if ($null -eq $_.SizeBytes)  { $why += 'size unparsed' }
            $_ | Select-Object @{N = 'Why'; E = { $why -join '; ' } }, *
        }
    )

    $totalBytes = if ($sized.Count) { [int64](($sized | Measure-Object -Property SizeBytes -Sum).Sum) } else { $null }

    [PSCustomObject]@{
        GeneratedAt         = $Now
        AgeDaysThreshold    = $AgeDays
        LargeThresholdBytes = $LargeThresholdBytes
        LargeThreshold      = Format-SnapshotBytes $LargeThresholdBytes
        All                 = $all
        Oldest              = $oldest
        Largest             = $largest
        OldCandidates       = $oldCandidates
        LargeCandidates     = $largeCandidates
        ClusterSummary      = $summary
        Unknown             = $unknown
        Stats               = [PSCustomObject]@{
            Total             = $recs.Count
            Clusters          = @($recs | Select-Object -ExpandProperty Cluster -Unique).Count
            WithSize          = $sized.Count
            WithCreateTime    = $dated.Count
            SizeUnknown       = $noSize.Count
            DateUnknown       = $noDate.Count
            Locked            = @($recs | Where-Object { $_.Locked }).Count
            TotalBytes        = $totalBytes
            TotalSize         = Format-SnapshotBytes $totalBytes
            OldCandidates     = $oldCandidates.Count
            LargeCandidates   = $largeCandidates.Count
        }
    }
}

Export-ModuleMember -Function @(
    'Get-OntapSnapshotFieldCatalog',
    'Get-SnapshotInventoryCommand',
    'Convert-OntapSize',
    'Format-SnapshotBytes',
    'Convert-OntapSnapshotTime',
    'ConvertFrom-OntapSnapshotCsv',
    'ConvertTo-SnapshotRecord',
    'Get-SnapshotReportSet'
)
