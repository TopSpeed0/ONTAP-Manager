<#
.SYNOPSIS
    File System Analytics (FSA) helpers for the DFS cleanup workflow.

.DESCRIPTION
    Wraps the ONTAP REST endpoints needed to decide whether a DFS-backed qtree or volume is
    cold enough to delete:

      Get-NaRestContext          Build auth headers / base URI once per run
      Get-NaVolume               Resolve a volume name to its UUID + FSA state
      Enable-NaVolumeAnalytics   Turn FSA on for a volume (gated by ShouldProcess)
      Get-NaDirectoryAnalytics   FSA byte histograms for one directory (qtree or volume root)
      Get-NaNewestTimestamp      Real per-file accessed/modified timestamps (recursive, bounded)
      Get-DFSCleanupVerdict      Apply the age thresholds and return a verdict

    Consolidates and replaces ONTAP\shares\Get-NetAppQtreeAnalytics.psm1 and
    ONTAP\shares\Get-NetAppFiles.psm1.

.NOTES
    Two things the superseded scripts got wrong for this purpose:

    1. Get-NetAppFiles queried with `order_by=size desc&max_records=1000`, then the caller
       sorted that result by accessed_time. On a directory with more than 1000 files that
       returns the newest of the 1000 LARGEST files — the actually-newest file can be absent.
       Age decisions made from it are wrong. Here the sort field matches the question.

    2. Get-NetAppQtreeAnalytics read histogram *labels* from the response root but *values*
       from a child record. That happens to work (ONTAP repeats the same labels in both), but
       it is fragile. Here labels and values always come from the same object.

    FSA histograms collapse their oldest bucket (e.g. "2022 or OLDER"). That is enough to
    prove a 3-year rule but NOT a 7-year rule — when the newest non-empty bucket is the
    collapsed one, the reported age is a LOWER BOUND and IsLowerBound is set. Callers that
    delete on a 7-year rule must require per-file proof (see Get-NaNewestTimestamp).
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------------------
# REST plumbing
# ---------------------------------------------------------------------------------------

function Get-NaRestContext {
    <#
    .SYNOPSIS
        Build a reusable REST context (headers + base URI) from a username and secure password.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RestHost,
        [Parameter(Mandatory)][string]$Username,
        [Parameter(Mandatory)][System.Security.SecureString]$Password,
        [switch]$SkipCertificateCheck
    )

    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    try {
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        $b64 = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("${Username}:${plain}"))
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    [PSCustomObject]@{
        BaseUri              = "https://$RestHost/api"
        Headers              = @{ Authorization = "Basic $b64"; Accept = 'application/json' }
        SkipCertificateCheck = [bool]$SkipCertificateCheck
    }
}

function Invoke-NaRest {
    <#
    .SYNOPSIS
        GET/PATCH an ONTAP REST path, following _links.next when the response is paged.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Context,
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('Get', 'Patch')][string]$Method = 'Get',
        [hashtable]$Body,
        [switch]$FollowPaging
    )

    $uri = if ($Path -match '^https?://') { $Path } else { "$($Context.BaseUri)$Path" }
    $all = [System.Collections.Generic.List[object]]::new()
    $first = $null

    while ($uri) {
        $splat = @{
            Method      = $Method
            Uri         = $uri
            Headers     = $Context.Headers
            ErrorAction = 'Stop'
        }
        if ($Context.SkipCertificateCheck) { $splat['SkipCertificateCheck'] = $true }
        if ($Body) {
            $splat['Body'] = ($Body | ConvertTo-Json -Depth 10)
            $splat['ContentType'] = 'application/json'
        }

        Write-Verbose "$Method $uri"
        $response = Invoke-RestMethod @splat

        if (-not $first) { $first = $response }

        if ($FollowPaging) {
            if ($response.PSObject.Properties.Name -contains 'records' -and $response.records) {
                $all.AddRange(@($response.records))
            }
            $next = $null
            if ($response.PSObject.Properties.Name -contains '_links' -and
                $response._links.PSObject.Properties.Name -contains 'next') {
                $next = $response._links.next.href
            }
            $uri = if ($next) { "https://$(([Uri]$Context.BaseUri).Host)$next" } else { $null }
        }
        else {
            $uri = $null
        }
    }

    if ($FollowPaging) {
        return [PSCustomObject]@{ Response = $first; Records = $all.ToArray() }
    }
    return $first
}

# ---------------------------------------------------------------------------------------
# Volume-level: UUID, FSA state, access-time tracking
# ---------------------------------------------------------------------------------------

function Get-NaVolume {
    <#
    .SYNOPSIS
        Resolve a volume by name+SVM and return its UUID, size and FSA/access-time state.
    .DESCRIPTION
        access_time_enabled is a separate switch from analytics.state. If access time
        tracking is off, by_accessed_time data is meaningless no matter what FSA reports —
        which is why both are surfaced here and checked by Get-DFSCleanupVerdict.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Context,
        [Parameter(Mandatory)][string]$VolumeName,
        [Parameter(Mandatory)][string]$Vserver
    )

    $fields = @(
        'uuid', 'name', 'size', 'space.used', 'state', 'nas.path', 'svm.name',
        'analytics.state', 'analytics.supported', 'analytics.initialization.state',
        'analytics.scan_progress', 'analytics.files_scanned', 'analytics.total_files',
        'access_time_enabled'
    ) -join ','

    $path = "/storage/volumes?name=$([Uri]::EscapeDataString($VolumeName))" +
            "&svm.name=$([Uri]::EscapeDataString($Vserver))&fields=$fields&return_timeout=120"

    $result = Invoke-NaRest -Context $Context -Path $path

    # Indexing [0] into an empty array throws under StrictMode, so the count is checked first.
    $records = @()
    if ($result.PSObject.Properties.Name -contains 'records' -and $result.records) {
        $records = @($result.records)
    }
    if ($records.Count -eq 0) {
        Write-Warning "Volume '$VolumeName' not found on SVM '$Vserver'."
        return $null
    }
    $record = $records[0]

    [PSCustomObject]@{
        Name                 = $record.name
        Uuid                 = $record.uuid
        Vserver              = $record.svm.name
        State                = $record.state
        JunctionPath         = $(if ($record.PSObject.Properties.Name -contains 'nas') { $record.nas.path } else { $null })
        SizeBytes            = $record.size
        UsedBytes            = $(if ($record.PSObject.Properties.Name -contains 'space') { $record.space.used } else { $null })
        AnalyticsSupported   = $(if ($record.analytics.PSObject.Properties.Name -contains 'supported') { $record.analytics.supported } else { $null })
        AnalyticsState       = $(if ($record.analytics.PSObject.Properties.Name -contains 'state') { $record.analytics.state } else { $null })
        AnalyticsInitState   = $(if ($record.analytics.PSObject.Properties.Name -contains 'initialization') { $record.analytics.initialization.state } else { $null })
        FilesScanned         = $(if ($record.analytics.PSObject.Properties.Name -contains 'files_scanned') { $record.analytics.files_scanned } else { $null })
        TotalFiles           = $(if ($record.analytics.PSObject.Properties.Name -contains 'total_files') { $record.analytics.total_files } else { $null })
        AccessTimeEnabled    = $(if ($record.PSObject.Properties.Name -contains 'access_time_enabled') { $record.access_time_enabled } else { $null })
        Raw                  = $record
    }
}

function Get-NaDirectoryEntries {
    <#
    .SYNOPSIS
        List one directory in a volume, reporting each entry's type (and symlink target).
    .DESCRIPTION
        `type` is what distinguishes a real folder from a symlink file from a regular file —
        the only reliable way to tell them apart on an ONTAP volume. For symlinks, `target`
        holds the link contents.

        Note: a widelink symlink's target (e.g. '/Link1') is NOT a filesystem path. It is a key
        into the CIFS widelink table, which maps '/Link1/' to share 'Link1$', whose own path is
        the real location ('/bigvol1/Link1_Q').
    .PARAMETER FirstPageOnly
        Stop after the first page instead of following paging to the end. For an is-it-empty
        probe that is all that is needed, and it matters: paging to the end of a directory
        holding 1.2M files costs hundreds of round trips to answer a yes/no question.
        Callers that need a complete listing must leave this off.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Context,
        [Parameter(Mandatory)][string]$VolumeUuid,
        [AllowEmptyString()][string]$Path = '',
        [int]$MaxRecords = 2000,
        [switch]$FirstPageOnly
    )

    $encoded = if ([string]::IsNullOrWhiteSpace($Path) -or $Path -eq '/') {
        ''
    }
    else {
        ($Path.Trim('/').Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
    }

    $uri = "/storage/volumes/$VolumeUuid/files/$encoded" +
           "?fields=name,type,target,size&max_records=$MaxRecords&return_timeout=120"

    try {
        $page = Invoke-NaRest -Context $Context -Path $uri -FollowPaging:(-not $FirstPageOnly)
    }
    catch {
        Write-Warning "Could not list '/$Path' in volume '$VolumeUuid': $($_.Exception.Message)"
        return @()
    }

    @($page.Records) | Where-Object { $_.name -notin @('.', '..') } | ForEach-Object {
        [PSCustomObject]@{
            Name   = $_.name
            Type   = $_.type
            Target = $(if ($_.PSObject.Properties.Name -contains 'target') { $_.target } else { $null })
            Size   = $(if ($_.PSObject.Properties.Name -contains 'size') { $_.size } else { $null })
        }
    }
}

function Find-NaDFSContainerVolumes {
    <#
    .SYNOPSIS
        Discover which volumes hold DFS widelink symlink FILES, by scanning, not by name.
    .DESCRIPTION
        `vserver cifs symlink show` keys widelinks on a bare relative name ('/Link1/') and never
        records which volume the symlink file physically lives in. There is no ONTAP command for
        that reverse lookup, so it must be discovered by scanning for entries of type 'symlink'.

        Deliberately makes NO assumption about volume naming. On this SVM the documented DFS
        roots were the *DFS* named volumes, but scanning found symlink files in VolX,
        VolY and VolZ too — someone added them outside the normal process. A
        name-based filter would have missed all three, and Phase 1 would then fail to unlink
        their symlink files.

        -MaxDepth > 0 also scans subdirectories, for symlinks placed inside a folder rather than
        at the volume root.

    .PARAMETER MaxUsedGB
        Skip volumes larger than this. 0 (default) scans everything. Anything skipped is
        reported in the returned SkippedVolumes list — a silent cap would read as "no containers
        here" when the volume was simply never looked at.

    .PARAMETER MaxDepth
        0 = volume root only (default). 1+ also descends that many directory levels.

    .OUTPUTS
        One object per container volume found, plus a final summary object
        (IsSummary = $true) listing skipped and failed volumes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Context,
        [Parameter(Mandatory)][string]$Vserver,
        [double]$MaxUsedGB = 0,
        [int]$MaxDepth = 0,
        [int]$MaxDirsPerVolume = 200
    )

    $skipped = [System.Collections.Generic.List[object]]::new()
    $failed = [System.Collections.Generic.List[object]]::new()
    $scanned = 0

    $volumes = @(Get-NaVolumeList -Context $Context -Vserver $Vserver)

    # Every other volume is junctioned as a subdirectory of the SVM root volume, so descending
    # into it re-reads those volumes through their mount points and counts every symlink twice.
    # Collect the junction names so traversal stops at a mount point.
    $junctionNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($v in $volumes) {
        if ($v.JunctionPath) {
            $first = @("$($v.JunctionPath)".Trim('/') -split '/' | Where-Object { $_ })
            if ($first.Count -ge 1) { [void]$junctionNames.Add($first[0]) }
        }
    }

    foreach ($v in $volumes) {
        $usedGb = if ($v.UsedBytes) { [double]$v.UsedBytes / 1GB } else { 0 }

        # The SVM root volume holds only junction mount points, never real DFS link files.
        if ($v.JunctionPath -eq '/') {
            $skipped.Add([PSCustomObject]@{ Volume = $v.Name; UsedGB = [math]::Round($usedGb, 2); Reason = 'SVM root volume — contains only junction mount points to other volumes' })
            continue
        }

        # An offline volume cannot be listed (the files endpoint returns 400). Reported as a
        # known-benign skip rather than a scan failure.
        if ($v.State -and $v.State -ne 'online') {
            $skipped.Add([PSCustomObject]@{ Volume = $v.Name; UsedGB = [math]::Round($usedGb, 2); Reason = "volume is $($v.State) — cannot be listed" })
            continue
        }

        if ($MaxUsedGB -gt 0 -and $usedGb -gt $MaxUsedGB) {
            $skipped.Add([PSCustomObject]@{ Volume = $v.Name; UsedGB = [math]::Round($usedGb, 2); Reason = "larger than MaxUsedGB ($MaxUsedGB)" })
            continue
        }

        $allSyms = [System.Collections.Generic.List[object]]::new()
        $allDirs = 0
        $queue = [System.Collections.Generic.Queue[object]]::new()
        $queue.Enqueue(@{ Path = ''; Depth = 0 })
        $dirBudgetHit = $false
        $listFailed = $null
        $visited = 0

        while ($queue.Count -gt 0) {
            if ($visited -ge $MaxDirsPerVolume) { $dirBudgetHit = $true; break }
            $node = $queue.Dequeue()
            $visited++

            $entries = @()
            try {
                $entries = @(Get-NaDirectoryEntries -Context $Context -VolumeUuid $v.Uuid -Path $node.Path -ErrorAction Stop)
            }
            catch {
                if ($node.Depth -eq 0) { $listFailed = $_.Exception.Message }
                continue
            }

            foreach ($e in $entries) {
                if ($e.Type -eq 'symlink') {
                    $allSyms.Add([PSCustomObject]@{
                        Name       = $e.Name
                        Type       = $e.Type
                        Target     = $e.Target
                        Size       = $e.Size
                        ParentPath = $node.Path
                        FilePath   = $(if ($node.Path) { "$($node.Path)/$($e.Name)" } else { $e.Name })
                    })
                }
                elseif ($e.Type -eq 'directory') {
                    $allDirs++
                    # .snapshot is the volume's snapshot mount, not user content. A name matching
                    # another volume's junction is a mount point — descending it would re-scan
                    # that volume and double-count its symlinks.
                    $isJunction = ($node.Depth -eq 0 -and $junctionNames.Contains($e.Name) -and $e.Name -ne $v.Name)
                    if ($node.Depth -lt $MaxDepth -and
                        $e.Name -notin @('.snapshot', 'System Volume Information') -and
                        -not $isJunction) {
                        $queue.Enqueue(@{ Path = $(if ($node.Path) { "$($node.Path)/$($e.Name)" } else { $e.Name }); Depth = $node.Depth + 1 })
                    }
                }
            }
        }

        if ($listFailed) {
            $failed.Add([PSCustomObject]@{ Volume = $v.Name; UsedGB = [math]::Round($usedGb, 2); Reason = $listFailed })
            continue
        }
        $scanned++
        if ($allSyms.Count -eq 0) { continue }

        [PSCustomObject]@{
            IsSummary       = $false
            Volume          = $v.Name
            Uuid            = $v.Uuid
            UsedGB          = [math]::Round($usedGb, 2)
            SymlinkCount    = $allSyms.Count
            DirCount        = $allDirs
            DirBudgetHit    = $dirBudgetHit
            NestedSymlinks  = @($allSyms | Where-Object { $_.ParentPath }).Count
            Symlinks        = $allSyms.ToArray()
        }
    }

    [PSCustomObject]@{
        IsSummary       = $true
        ScannedVolumes  = $scanned
        SkippedVolumes  = $skipped.ToArray()
        FailedVolumes   = $failed.ToArray()
        MaxDepth        = $MaxDepth
    }
}

function Resolve-NaSymlinkChain {
    <#
    .SYNOPSIS
        Turn the raw container-volume scan into the full symlink map: file -> widelink -> share
        -> share path -> target volume/qtree.
    .DESCRIPTION
        Shared by Find-NcSymlinkFile.ps1 and by the Symlink_Map worksheet, so the two can never
        disagree about what a symlink resolves to. Pure function over already-fetched tables —
        no cluster calls — which is what makes it testable offline.
    .PARAMETER Containers
        Non-summary rows from Find-NaDFSContainerVolumes.
    .PARAMETER WidelinkMap
        Hashtable: widelink target key (trimmed, lower-cased) -> share name.
    .PARAMETER ShareMap
        Hashtable: share name -> object with a .Path property.
    .PARAMETER QtreeSet
        Set of "volume/qtree" strings, used to VERIFY a qtree rather than infer it from the name.
    .PARAMETER CifsAlias
        Host part used to build the UNC column. Optional; omitted leaves UncPath $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Containers,
        [Parameter(Mandatory)][hashtable]$WidelinkMap,
        [Parameter(Mandatory)][hashtable]$ShareMap,
        [Parameter(Mandatory)]$QtreeSet,
        [string]$CifsAlias
    )

    $out = [System.Collections.Generic.List[object]]::new()

    foreach ($cv in @($Containers)) {
        foreach ($s in @($cv.Symlinks)) {
            $key = "$($s.Target)".Trim('/').ToLowerInvariant()
            $share = if ($WidelinkMap.ContainsKey($key)) { $WidelinkMap[$key] } else { $null }

            $tgtSharePath = $null; $tgtVolume = $null; $tgtQtree = $null
            $tgtIsQtree = $null; $tgtKind = $null

            if ($share -and $ShareMap.ContainsKey($share)) {
                $shObj = $ShareMap[$share]
                $tgtSharePath = $shObj.Path
                $parts = @("$($shObj.Path)".Trim('/') -split '/' | Where-Object { $_ })
                if ($parts.Count -ge 1) { $tgtVolume = $parts[0] }
                if ($parts.Count -ge 2) { $tgtQtree = $parts[1] }

                if ($parts.Count -le 1) {
                    $tgtKind = 'VolumeRoot'
                    $tgtIsQtree = $false
                }
                else {
                    # Verified against the qtree table, never inferred from the name. A path like
                    # /vol/lookalike_Q looks exactly like a qtree but can be a plain directory —
                    # and deleting it as a qtree would take its siblings.
                    $tgtIsQtree = $QtreeSet.Contains("$tgtVolume/$tgtQtree")
                    $tgtKind = if ($parts.Count -eq 2 -and $tgtIsQtree) { 'Qtree' } else { 'Directory' }
                }
            }

            $out.Add([PSCustomObject]@{
                Volume        = $cv.Volume
                FilePath      = $s.FilePath
                FullPath      = "/vol/$($cv.Volume)/$($s.FilePath)"
                UncPath       = if ($CifsAlias) { "\\$CifsAlias\$($cv.Volume)`$\$(($s.FilePath) -replace '/','\')" } else { $null }
                Target        = $s.Target
                TargetKey     = $key
                IsWidelink    = [bool]$share
                Share         = $share
                TargetPath    = $tgtSharePath
                TargetVolume  = $tgtVolume
                TargetQtree   = $tgtQtree
                TargetIsQtree = $tgtIsQtree
                TargetKind    = $tgtKind
                Nested        = [bool]$s.ParentPath
                SizeBytes     = $s.Size
            })
        }
    }

    return @($out | Sort-Object Volume, FilePath)
}

function Get-DFSAnomaly {
    <#
    .SYNOPSIS
        Collect the things that will bite during deletion, ranked by severity.
    .DESCRIPTION
        Every one of these was found the hard way on a real namespace. Pure function over the
        symlink map plus the widelink table, so it can be tested without a cluster.

        Severity vocabulary, highest first:
          DO NOT DELETE  removing the named object would destroy data beyond the intended target
          Care           the object can go, but only if every route to it goes too
          Review         something is unreachable or inconsistent and needs a human look
          Note           true and worth knowing, but not a hazard
    .PARAMETER SymlinkMap
        Output of Resolve-NaSymlinkChain.
    .PARAMETER WidelinkMap
        Hashtable: widelink target key -> share name. Needed to spot widelinks with NO symlink
        file, which by definition cannot appear in the symlink map.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$SymlinkMap,
        [Parameter(Mandatory)][hashtable]$WidelinkMap
    )

    $a = [System.Collections.Generic.List[object]]::new()
    $add = {
        param($sev, $type, $obj, $detail, $impact)
        $a.Add([PSCustomObject]@{ Severity = $sev; Type = $type; Object = $obj; Detail = $detail; Impact = $impact })
    }

    # --- Several widelinks -> one share. Removing the share breaks the other link(s). ---
    $byShare = @{}
    foreach ($k in $WidelinkMap.Keys) {
        $sh = $WidelinkMap[$k]
        if (-not $sh) { continue }
        if (-not $byShare.ContainsKey($sh)) { $byShare[$sh] = [System.Collections.Generic.List[string]]::new() }
        $byShare[$sh].Add("/$($k.Trim('/'))/")
    }
    foreach ($sh in ($byShare.Keys | Sort-Object)) {
        if ($byShare[$sh].Count -gt 1) {
            & $add 'DO NOT DELETE' 'Several WIDELINKS -> one share' $sh (($byShare[$sh] | Sort-Object) -join ' | ') `
                   'Removing the share breaks the other link(s)'
        }
    }

    # --- Share targets a DIRECTORY, not a qtree. A qtree delete would take the siblings. ---
    foreach ($r in @($SymlinkMap | Where-Object { $_.TargetKind -eq 'Directory' } |
                     Sort-Object Share -Unique)) {
        & $add 'DO NOT DELETE' 'Share targets a DIRECTORY, not a qtree' $r.Share `
               "$($r.TargetPath) - '$($r.TargetQtree)' is a plain folder" `
               'Delete as a directory; a qtree delete would take siblings'
    }

    # --- Several symlink FILES -> one widelink. Every file must go to retire the link. ---
    foreach ($g in @($SymlinkMap | Where-Object { $_.TargetKey } | Group-Object TargetKey |
                     Where-Object { $_.Count -gt 1 } | Sort-Object Name)) {
        & $add 'Care' 'Several symlink FILES -> one widelink' "/$($g.Name)" `
               ((@($g.Group | ForEach-Object { "$($_.Volume)/$($_.FilePath)" }) | Sort-Object) -join ' | ') `
               'Remove every file to retire the link'
    }

    # --- Widelink table entry with no symlink file anywhere: unreachable from any path. ---
    $haveFile = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($r in @($SymlinkMap)) { if ($r.TargetKey) { [void]$haveFile.Add($r.TargetKey) } }
    foreach ($k in ($WidelinkMap.Keys | Sort-Object)) {
        if (-not $haveFile.Contains($k)) {
            & $add 'Review' 'Widelink with no symlink file' "/$($k.Trim('/'))/" `
                   "table entry -> $($WidelinkMap[$k]), no symlink file in any volume" `
                   'Unreachable from any namespace path'
        }
    }

    # --- Plain UNIX symlinks: application links, not DFS. Cleanup must ignore them. ---
    foreach ($r in @($SymlinkMap | Where-Object { -not $_.IsWidelink } | Sort-Object Volume, FilePath)) {
        & $add 'Note' 'Plain UNIX symlink (not DFS)' "$($r.Volume)/$($r.FilePath)" `
               "target $($r.Target)" 'Application link - DFS cleanup must ignore it'
    }

    # --- Symlink files below a volume root: a roots-only scan would miss these entirely. ---
    foreach ($r in @($SymlinkMap | Where-Object { $_.Nested } | Sort-Object Volume, FilePath)) {
        & $add 'Note' 'Symlink file below the volume root' "$($r.Volume)/$($r.FilePath)" `
               "target $($r.Target)" 'Root-only scans would miss it'
    }

    $order = @{ 'DO NOT DELETE' = 0; 'Care' = 1; 'Review' = 2; 'Note' = 3 }
    return @($a | Sort-Object @{ E = { $order[$_.Severity] } }, Type, Object)
}

function Get-DFSSubPathSuffix {
    <#
    .SYNOPSIS
        Decide whether trailing DFS path components were consumed by the resolver or are a
        folder path inside the target share.
    .DESCRIPTION
        Pure function — no cluster access — because getting it wrong deletes the wrong thing.

        `\\ns\dfs\Dept\SubOne` resolves to the 'IT' widelink and returns share IT$ at
        /datavol2/Dept_Q. The 'SubOne' component is DISCARDED by the resolver, so acting on
        the result would delete qtree Dept_Q and every sibling folder in it.

        The resolver's genuine nested-DFS-link branch returns LINK ending with the extra
        component (/vol/dfsroot/Dept/SubOne). The collapsed case returns LINK ending at the
        widelink (/vol/dfsroot/Dept). Comparing the leaf distinguishes them; when they differ the
        components are returned as a sub-path, because a scoped directory delete can never
        destroy siblings.

    .PARAMETER DfsPath
        The original UNC path, e.g. '\\ns\dfs\Dept\SubOne'.

    .PARAMETER Link
        The LINK value returned by Get-DFSNameSpaceRoot, e.g. '/vol/dfsroot/Dept'.

    .OUTPUTS
        Forward-slash sub-path relative to the share ('SubOne'), or '' when there is none.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$DfsPath,
        [AllowEmptyString()][AllowNull()][string]$Link
    )

    $tokens = @($DfsPath.Trim() -split '\\+' | Where-Object { $_ -ne '' })
    if ($tokens.Count -le 3) { return '' }

    $extra = @($tokens[3..($tokens.Count - 1)])

    $linkLeaf = ''
    if (-not [string]::IsNullOrWhiteSpace($Link) -and $Link -ne 'none') {
        $parts = @($Link.TrimEnd('/') -split '/' | Where-Object { $_ -ne '' })
        if ($parts.Count -gt 0) { $linkLeaf = $parts[-1] }
    }

    if ($linkLeaf -eq $extra[-1]) { return '' }
    return ($extra -join '/')
}

function Get-DFSDeleteClassification {
    <#
    .SYNOPSIS
        Map a resolved DFS target to the correct delete primitive.
    .DESCRIPTION
        Pure function. Depth is checked BEFORE type, and a qtree is only accepted when it was
        verified to exist — never inferred from the path. Anything else becomes a scoped
        directory delete, which is the safe default: it cannot take siblings with it.

    .PARAMETER SharePath
        Share path '/<volume>/<inside...>'. May be empty for hidden-share shapes.

    .PARAMETER UnixPath
        Fallback used when SharePath is empty. The resolver's hidden-share branch
        (\\ns\TempShare$) puts the share path here instead. A widelink UnixPath is a single
        component ('/Sample/') and is ignored; a share path has two or more ('/datavol4/Tmp_Q').

    .PARAMETER SubPathSuffix
        Result of Get-DFSSubPathSuffix.

    .PARAMETER QtreeExists
        Whether the qtree named by the path was confirmed present on the cluster.

    .PARAMETER IsWidelink
        Whether the target is reached through a DFS widelink.

    .OUTPUTS
        Object with TargetType, DeleteMethod and DeleteRelPath (relative to the volume root).
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()][AllowNull()][string]$SharePath,
        [AllowEmptyString()][AllowNull()][string]$UnixPath,
        [AllowEmptyString()][AllowNull()][string]$SubPathSuffix,
        [AllowNull()][object]$QtreeExists,
        [bool]$IsWidelink
    )

    $effective = $SharePath
    if ([string]::IsNullOrWhiteSpace($effective) -and -not [string]::IsNullOrWhiteSpace($UnixPath)) {
        $up = @($UnixPath.Trim('/') -split '/' | Where-Object { $_ -ne '' })
        if ($up.Count -ge 2) { $effective = $UnixPath }
    }

    $spParts = @()
    if (-not [string]::IsNullOrWhiteSpace($effective)) {
        $spParts = @($effective.Trim('/') -split '/' | Where-Object { $_ -ne '' })
    }
    $insideVolume = if ($spParts.Count -gt 1) { (($spParts[1..($spParts.Count - 1)]) -join '/') } else { '' }

    $relParts = @(@($insideVolume, $SubPathSuffix) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $deleteRel = ($relParts -join '/')

    $suffix = if ($IsWidelink) { 'Widelink' } else { 'DirectShare' }
    $hasSub = -not [string]::IsNullOrWhiteSpace($SubPathSuffix)

    if ($spParts.Count -le 1 -and -not $hasSub) {
        $type = "Volume$suffix"; $method = 'Volume'
    }
    elseif ($spParts.Count -eq 2 -and -not $hasSub -and $QtreeExists -eq $true) {
        $type = "Qtree$suffix"; $method = 'Qtree'
    }
    else {
        $type = "Subfolder$suffix"; $method = 'Directory'
    }

    [PSCustomObject]@{
        TargetType        = $type
        DeleteMethod      = $method
        SharePathInVolume = $insideVolume
        DeleteRelPath     = $deleteRel
    }
}

function Get-NaVolumeList {
    <#
    .SYNOPSIS
        List every volume on an SVM with its FSA and access-time state.
    .DESCRIPTION
        Preferred over probing a hardcoded name list: the protected-volume list is a deletion
        guard, not an inventory, and most of its entries do not exist on any given SVM.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Context,
        [Parameter(Mandatory)][string]$Vserver
    )

    $fields = @(
        'uuid', 'name', 'size', 'space.used', 'state', 'svm.name', 'nas.path',
        'analytics.state', 'analytics.supported', 'analytics.initialization.state',
        'analytics.scan_progress', 'analytics.files_scanned', 'analytics.total_files',
        'access_time_enabled'
    ) -join ','

    $path = "/storage/volumes?svm.name=$([Uri]::EscapeDataString($Vserver))" +
            "&fields=$fields&max_records=500&order_by=name&return_timeout=120"

    $page = Invoke-NaRest -Context $Context -Path $path -FollowPaging

    foreach ($r in @($page.Records)) {
        $a = $r.analytics
        $has = { param($o, $n) $o -and ($o.PSObject.Properties.Name -contains $n) }

        # scan_progress is not always populated; derive it from the file counts when missing so
        # "is the scan done yet" is answerable either way.
        $progress = $(if (& $has $a 'scan_progress') { $a.scan_progress } else { $null })
        $scanned = $(if (& $has $a 'files_scanned') { $a.files_scanned } else { $null })
        $total = $(if (& $has $a 'total_files') { $a.total_files } else { $null })
        if ($null -eq $progress -and $total -and [double]$total -gt 0) {
            $progress = [math]::Round(([double]$scanned / [double]$total) * 100, 1)
        }

        [PSCustomObject]@{
            Name               = $r.name
            Uuid               = $r.uuid
            Vserver            = $r.svm.name
            State              = $r.state
            JunctionPath       = $(if (& $has $r 'nas') { $r.nas.path } else { $null })
            SizeBytes          = $r.size
            UsedBytes          = $(if (& $has $r 'space') { $r.space.used } else { $null })
            AnalyticsSupported = $(if (& $has $a 'supported') { $a.supported } else { $null })
            AnalyticsState     = $(if (& $has $a 'state') { $a.state } else { $null })
            AnalyticsInitState = $(if (& $has $a 'initialization') { $a.initialization.state } else { $null })
            ScanProgress       = $progress
            FilesScanned       = $scanned
            TotalFiles         = $total
            AccessTimeEnabled  = $(if (& $has $r 'access_time_enabled') { $r.access_time_enabled } else { $null })
        }
    }
}

function Remove-NaDirectory {
    <#
    .SYNOPSIS
        Recursively delete a directory (and its contents) inside a volume, via REST.
    .DESCRIPTION
        Needed for shares whose path points at a plain Windows-created folder rather than a
        qtree. Removing the qtree in that situation would destroy every sibling folder in it —
        so this is the only correct primitive for that shape.

        DELETE /storage/volumes/{uuid}/files/{path}?recurse=true
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Context,
        [Parameter(Mandatory)][string]$VolumeUuid,
        [Parameter(Mandatory)][string]$Path,
        [int]$TimeoutSeconds = 600
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Trim('/') -eq '') {
        throw 'Remove-NaDirectory refuses an empty path — that would target the volume root.'
    }

    $rel = $Path.Trim('/')
    $encoded = ($rel.Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
    $uri = "$($Context.BaseUri)/storage/volumes/$VolumeUuid/files/$encoded" +
           "?recurse=true&return_timeout=$TimeoutSeconds"

    if (-not $PSCmdlet.ShouldProcess("/$rel in volume $VolumeUuid", 'Recursively delete directory and all contents')) {
        return $false
    }

    $splat = @{
        Method      = 'Delete'
        Uri         = $uri
        Headers     = $Context.Headers
        ErrorAction = 'Stop'
    }
    if ($Context.SkipCertificateCheck) { $splat['SkipCertificateCheck'] = $true }

    Write-Verbose "DELETE $uri"
    $response = Invoke-RestMethod @splat

    # A long recursive delete comes back as an async job; report it rather than claiming done.
    if ($response -and $response.PSObject.Properties.Name -contains 'job') {
        Write-Warning "Recursive delete of '/$rel' was accepted as background job $($response.job.uuid). Verify completion before treating the path as gone."
        return $response.job.uuid
    }
    return $true
}

function Enable-NaVolumeAnalytics {
    <#
    .SYNOPSIS
        Turn File System Analytics on for a volume.
    .DESCRIPTION
        Enabling FSA starts an initialization scan that walks the whole volume. On large
        volumes this consumes cluster resources for a while, so this is gated behind
        ShouldProcess and is never called implicitly by the reporting modes.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Context,
        [Parameter(Mandatory)][string]$VolumeUuid,
        [Parameter(Mandatory)][string]$VolumeName,
        [switch]$EnableAccessTime
    )

    $body = @{ analytics = @{ state = 'on' } }
    $what = "File System Analytics"
    if ($EnableAccessTime) {
        $body['access_time_enabled'] = $true
        $what += " and access-time tracking"
    }

    if ($PSCmdlet.ShouldProcess("Volume '$VolumeName'", "Enable $what (starts a full initialization scan)")) {
        Invoke-NaRest -Context $Context -Path "/storage/volumes/$VolumeUuid" -Method Patch -Body $body | Out-Null
        Write-Host "Enabled $what on '$VolumeName'. Initialization scan started — analytics data is incomplete until it finishes." -ForegroundColor Yellow
        return $true
    }
    return $false
}

# ---------------------------------------------------------------------------------------
# Histogram parsing
# ---------------------------------------------------------------------------------------

function ConvertFrom-NaTimeLabel {
    <#
    .SYNOPSIS
        Turn an FSA histogram label into a comparable date plus a collapse flag.
    .DESCRIPTION
        ONTAP labels the recent end of the histogram finely and collapses the old end into a
        single bucket. Observed forms include "2026-W29", "2025-Q1", "2024", "--2Y",
        "2022 or OLDER" and "unknown". Rather than assume one format, every known shape is
        handled and anything unrecognised is returned as Kind='Unparsed' so it shows up in
        the report instead of being silently treated as old.

        NewestInstant is the most recent moment the bucket can represent — the correct edge
        to use when asking "how long since anything was touched".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Label,
        [Parameter(Mandatory)][datetime]$Now
    )

    $l = $Label.Trim()
    $out = [ordered]@{ Label = $Label; Kind = 'Unparsed'; NewestInstant = $null; IsCollapsed = $false }

    switch -Regex ($l) {
        '^unknown$' {
            $out.Kind = 'Unknown'
            break
        }
        # Collapsed oldest bucket: "--2Y", "-2Y", "2022 or OLDER", "or older"
        '(?i)or\s+older' {
            $out.Kind = 'Collapsed'; $out.IsCollapsed = $true
            if ($l -match '(\d{4})') {
                # "2022 or OLDER" — newest possible instant is the end of that year
                $out.NewestInstant = [datetime]::new([int]$Matches[1], 12, 31, 23, 59, 59)
            }
            break
        }
        # "--2022" — ONTAP's actual collapsed oldest bucket: that year and everything before it.
        # Must be tested before the -<n><unit> and bare-year patterns.
        '^-{1,2}(\d{4})$' {
            $out.Kind = 'Collapsed'; $out.IsCollapsed = $true
            $out.NewestInstant = [datetime]::new([int]$Matches[1], 12, 31, 23, 59, 59)
            break
        }
        '^-{1,2}(\d+)([YMWD])$' {
            $n = [int]$Matches[1]
            $out.Kind = 'Collapsed'; $out.IsCollapsed = $true
            $out.NewestInstant = switch ($Matches[2]) {
                'Y' { $Now.AddYears(-$n) }
                'M' { $Now.AddMonths(-$n) }
                'W' { $Now.AddDays(-7 * $n) }
                'D' { $Now.AddDays(-$n) }
            }
            break
        }
        # "2026-W29" / "2026 - WEEK 29"
        '(?i)^(\d{4})\s*-\s*W(?:EEK)?\s*(\d{1,2})$' {
            $year = [int]$Matches[1]; $week = [int]$Matches[2]
            $out.Kind = 'Week'
            $jan4 = [datetime]::new($year, 1, 4)
            $weekStart = $jan4.AddDays(-([int]$jan4.DayOfWeek + 6) % 7).AddDays(7 * ($week - 1))
            $out.NewestInstant = $weekStart.AddDays(7).AddSeconds(-1)
            break
        }
        # "2025-Q1" / "2025 Q1"
        '(?i)^(\d{4})\s*-?\s*Q([1-4])$' {
            $year = [int]$Matches[1]; $q = [int]$Matches[2]
            $out.Kind = 'Quarter'
            $out.NewestInstant = [datetime]::new($year, 3 * $q, 1).AddMonths(1).AddSeconds(-1)
            break
        }
        # "2025-07"
        '^(\d{4})-(\d{1,2})$' {
            $year = [int]$Matches[1]; $m = [int]$Matches[2]
            if ($m -ge 1 -and $m -le 12) {
                $out.Kind = 'Month'
                $out.NewestInstant = [datetime]::new($year, $m, 1).AddMonths(1).AddSeconds(-1)
            }
            break
        }
        '^(\d{4})$' {
            $out.Kind = 'Year'
            $out.NewestInstant = [datetime]::new([int]$Matches[1], 12, 31, 23, 59, 59)
            break
        }
    }

    # A bucket edge in the future (current partial week/quarter) is clamped to now.
    if ($out.NewestInstant -and $out.NewestInstant -gt $Now) { $out.NewestInstant = $Now }

    [PSCustomObject]$out
}

function Get-NaDirectoryAnalytics {
    <#
    .SYNOPSIS
        Return the FSA byte histograms for a single directory (a qtree, or the volume root).
    .DESCRIPTION
        GET /storage/volumes/{uuid}/files/{path} returns the CONTENTS of {path} as records,
        and the analytics of {path} ITSELF in the response's top-level `analytics` object.
        Labels and values are therefore both taken from that one object — no cross-referencing
        between response root and child records.

        Pass -Path '' (or '/') for the volume root.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Context,
        [Parameter(Mandatory)][string]$VolumeUuid,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [datetime]$Now = (Get-Date)
    )

    $encoded = if ([string]::IsNullOrWhiteSpace($Path) -or $Path -eq '/') {
        ''
    }
    else {
        ($Path.Trim('/').Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
    }

    $uri = "/storage/volumes/$VolumeUuid/files/$encoded" +
           "?fields=analytics,name,type&type=directory&max_records=10&return_timeout=120"

    try {
        $response = Invoke-NaRest -Context $Context -Path $uri
    }
    catch {
        # A 404 here is NOT "no analytics yet" — it means the path does not exist on the volume.
        # Those are opposite instructions: one says wait for the scan, the other says the row is
        # already done. Reporting a missing path as NO_ANALYTICS told the operator to keep waiting
        # for data that can never arrive. Verified in production: a parent qtree listed 22
        # subdirectories and not one matched the three tracker rows pointing "into" it, and one
        # share's path named a qtree absent from both the qtree table and the volume root.
        if ($_.Exception.Message -match '\b404\b') {
            Write-Warning "Path '$Path' does not exist in volume '$VolumeUuid' (404) — target is gone, not unscanned."
            return [PSCustomObject]@{
                Path = $Path; PathMissing = $true; HasData = $false
                BytesUsed = $null; FileCount = $null; SubdirCount = $null
                IncompleteData = $null; Buckets = @(); RawLabels = @()
            }
        }
        Write-Warning "FSA query failed for volume '$VolumeUuid' path '$Path': $($_.Exception.Message)"
        return $null
    }

    # The queried directory's OWN analytics is the record named '.'. The response-root
    # `analytics` object carries only the shared `labels` array — no values. And records also
    # include '..', the PARENT: on a qtree under bigvol1 that is the whole 37 TB volume, so picking
    # the wrong record silently reports the entire volume instead of the target.
    $records = @()
    if ($response.PSObject.Properties.Name -contains 'records' -and $response.records) {
        $records = @($response.records)
    }
    $self = $records | Where-Object { $_.name -eq '.' } | Select-Object -First 1

    if (-not $self -or -not ($self.PSObject.Properties.Name -contains 'analytics') -or -not $self.analytics) {
        Write-Warning "No '.' analytics record for volume '$VolumeUuid' path '$Path' — File System Analytics is off, still initializing, or the path does not exist."
        return $null
    }

    $a = $self.analytics

    # Labels live at the response root; values live on the record.
    $rootLabels = @{}
    if ($response.PSObject.Properties.Name -contains 'analytics' -and $response.analytics) {
        foreach ($node in @('by_accessed_time', 'by_modified_time')) {
            if ($response.analytics.PSObject.Properties.Name -contains $node) {
                $rootLabels[$node] = @($response.analytics.$node.bytes_used.labels)
            }
        }
    }

    $buckets = @()
    $ontapNewest = @{}
    $ontapOldest = @{}

    foreach ($dim in @(
            @{ Name = 'Accessed'; Node = 'by_accessed_time' },
            @{ Name = 'Modified'; Node = 'by_modified_time' })) {

        if (-not ($a.PSObject.Properties.Name -contains $dim.Node)) { continue }
        $hist = $a.($dim.Node).bytes_used
        if (-not $hist) { continue }

        # ONTAP reports the newest/oldest non-empty bucket itself — more trustworthy than
        # re-deriving it, and it is the field System Manager displays.
        if ($hist.PSObject.Properties.Name -contains 'newest_label') { $ontapNewest[$dim.Name] = $hist.newest_label }
        if ($hist.PSObject.Properties.Name -contains 'oldest_label') { $ontapOldest[$dim.Name] = $hist.oldest_label }

        $labels = if ($hist.PSObject.Properties.Name -contains 'labels' -and $hist.labels) {
            @($hist.labels)
        }
        elseif ($rootLabels.ContainsKey($dim.Node)) {
            @($rootLabels[$dim.Node])
        }
        else { @() }

        $values = @($hist.values)
        for ($i = 0; $i -lt $labels.Count; $i++) {
            $parsed = ConvertFrom-NaTimeLabel -Label ([string]$labels[$i]) -Now $Now
            $raw = if ($i -lt $values.Count) { $values[$i] } else { $null }
            $buckets += [PSCustomObject]@{
                Dimension     = $dim.Name
                Label         = $parsed.Label
                Kind          = $parsed.Kind
                NewestInstant = $parsed.NewestInstant
                IsCollapsed   = $parsed.IsCollapsed
                Bytes         = if ($null -eq $raw) { [int64]0 } else { [int64]$raw }
            }
        }
    }

    [PSCustomObject]@{
        Path           = $Path
        # HasData distinguishes "FSA says this is empty" from "FSA told us nothing" — the
        # difference between a legitimate EMPTY verdict and no verdict at all.
        HasData        = ($a.PSObject.Properties.Name -contains 'bytes_used')
        IncompleteData = $(if ($a.PSObject.Properties.Name -contains 'incomplete_data') { $a.incomplete_data } else { $null })
        BytesUsed      = $(if ($a.PSObject.Properties.Name -contains 'bytes_used') { $a.bytes_used } else { $null })
        FileCount      = $(if ($a.PSObject.Properties.Name -contains 'file_count') { $a.file_count } else { $null })
        SubdirCount    = $(if ($a.PSObject.Properties.Name -contains 'subdir_count') { $a.subdir_count } else { $null })
        Buckets        = $buckets
        OntapNewest    = $ontapNewest
        OntapOldest    = $ontapOldest
        RawLabels      = @($buckets | Where-Object Dimension -eq 'Accessed' | Select-Object -ExpandProperty Label)
        Raw            = $a
    }
}

function Get-NaBucketSummary {
    <#
    .SYNOPSIS
        Reduce one dimension's buckets to: newest non-empty bucket, its age, and whether
        that age is only a lower bound.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Buckets,
        [Parameter(Mandatory)][ValidateSet('Accessed', 'Modified')][string]$Dimension,
        [datetime]$Now = (Get-Date)
    )

    $dim = @($Buckets | Where-Object { $_.Dimension -eq $Dimension })
    $nonEmpty = @($dim | Where-Object { $_.Bytes -gt 0 })

    # Measure-Object emits NOTHING for an empty pipeline, so ".Sum" on its result throws under
    # StrictMode. That is the common case here (most histograms have no 'unknown' bucket), so
    # the sum is done explicitly rather than through Measure-Object.
    $totalBytes = [int64]0
    foreach ($b in $dim) { if ($null -ne $b.Bytes) { $totalBytes += [int64]$b.Bytes } }

    $unknownBytes = [int64]0
    foreach ($b in $dim) {
        if ($b.Kind -eq 'Unknown' -and $null -ne $b.Bytes) { $unknownBytes += [int64]$b.Bytes }
    }

    $unparsed = @($nonEmpty | Where-Object { $_.Kind -eq 'Unparsed' } | Select-Object -ExpandProperty Label -Unique)

    # Only datable buckets can answer "how long since". Unknown/Unparsed are reported
    # separately so they can't be mistaken for "old".
    $datable = @($nonEmpty | Where-Object { $null -ne $_.NewestInstant } | Sort-Object NewestInstant -Descending)
    $newest = $datable | Select-Object -First 1

    [PSCustomObject]@{
        Dimension        = $Dimension
        TotalBytes       = $totalBytes
        UnknownBytes     = $unknownBytes
        UnparsedLabels   = $unparsed
        NewestLabel      = $(if ($newest) { $newest.Label } else { $null })
        NewestInstant    = $(if ($newest) { $newest.NewestInstant } else { $null })
        YearsSinceNewest = $(if ($newest) { [math]::Round(($Now - $newest.NewestInstant).TotalDays / 365.25, 2) } else { $null })
        IsLowerBound     = [bool]($newest -and $newest.IsCollapsed)
        HasData          = [bool]$newest
    }
}

# ---------------------------------------------------------------------------------------
# Per-file timestamps — the only way to prove a long (7 year) age
# ---------------------------------------------------------------------------------------

function Get-NaNewestTimestamp {
    <#
    .SYNOPSIS
        Walk a directory tree and return the true newest accessed_time / modified_time.
    .DESCRIPTION
        The ONTAP files endpoint is per-directory, not recursive, so this walks subdirectories
        breadth-first under a node budget. If the budget or depth limit is hit before the walk
        completes, Complete is $false — callers must NOT treat an incomplete walk as proof.
        That is the difference between "we checked" and "we looked at some of it".

        Sorted by the field being measured (not by size), so the first record of the first
        page is genuinely the newest in that directory.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Context,
        [Parameter(Mandatory)][string]$VolumeUuid,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [int]$MaxRecords = 5000,
        [int]$MaxDepth = 12,
        [int]$MaxDirectories = 2000
    )

    $queue = [System.Collections.Generic.Queue[object]]::new()
    $queue.Enqueue(@{ Path = $Path.Trim('/'); Depth = 0 })

    $newestAccessed = $null
    $newestModified = $null
    $newestName = $null
    $dirsVisited = 0
    $filesSeen = 0
    $complete = $true
    $errors = @()

    while ($queue.Count -gt 0) {
        if ($dirsVisited -ge $MaxDirectories) {
            $complete = $false
            $errors += "Directory budget ($MaxDirectories) exhausted with $($queue.Count) directories still unvisited."
            break
        }

        $node = $queue.Dequeue()
        $dirsVisited++

        $encoded = if ([string]::IsNullOrWhiteSpace($node.Path)) {
            ''
        }
        else {
            ($node.Path.Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
        }

        $uri = "/storage/volumes/$VolumeUuid/files/$encoded" +
               "?fields=name,type,size,accessed_time,modified_time" +
               "&order_by=accessed_time%20desc&max_records=$MaxRecords&return_timeout=120"

        try {
            $page = Invoke-NaRest -Context $Context -Path $uri -FollowPaging
            $records = $page.Records
        }
        catch {
            # order_by on accessed_time is not accepted by every ONTAP release; fall back to
            # an unsorted read and take the max client-side. Same answer, more records read.
            try {
                $uriPlain = "/storage/volumes/$VolumeUuid/files/$encoded" +
                            "?fields=name,type,size,accessed_time,modified_time" +
                            "&max_records=$MaxRecords&return_timeout=120"
                $page = Invoke-NaRest -Context $Context -Path $uriPlain -FollowPaging
                $records = $page.Records
            }
            catch {
                $complete = $false
                $errors += "Failed to list '/$($node.Path)': $($_.Exception.Message)"
                continue
            }
        }

        foreach ($r in $records) {
            $name = $r.name
            if ($name -in @('.', '..')) { continue }

            $childPath = if ($node.Path) { "$($node.Path)/$name" } else { $name }

            if ($r.type -eq 'directory') {
                if ($node.Depth + 1 -le $MaxDepth) {
                    $queue.Enqueue(@{ Path = $childPath; Depth = $node.Depth + 1 })
                }
                else {
                    $complete = $false
                    $errors += "Depth limit ($MaxDepth) reached at '/$childPath'."
                }
                continue
            }

            $filesSeen++

            if ($r.PSObject.Properties.Name -contains 'accessed_time' -and $r.accessed_time) {
                $at = [datetime]$r.accessed_time
                if (-not $newestAccessed -or $at -gt $newestAccessed) {
                    $newestAccessed = $at
                    $newestName = $childPath
                }
            }
            if ($r.PSObject.Properties.Name -contains 'modified_time' -and $r.modified_time) {
                $mt = [datetime]$r.modified_time
                if (-not $newestModified -or $mt -gt $newestModified) { $newestModified = $mt }
            }
        }
    }

    [PSCustomObject]@{
        Path            = $Path
        NewestAccessed  = $newestAccessed
        NewestModified  = $newestModified
        NewestFile      = $newestName
        FilesSeen       = $filesSeen
        DirsVisited     = $dirsVisited
        Complete        = $complete
        Notes           = $errors
    }
}

# ---------------------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------------------

function Get-DFSCleanupVerdict {
    <#
    .SYNOPSIS
        Apply the configured age thresholds to FSA (and optional per-file) evidence.
    .DESCRIPTION
        The rule being implemented: no new files AND no access within CandidateYears makes a
        target a deletion candidate; the same over ImmediateYears makes it eligible for
        immediate deletion. Both dimensions must agree — a cold-read/hot-write directory is
        not idle.

        Verdicts:
          NO_ANALYTICS  FSA off, unsupported, or still initializing — no decision possible
          NO_ATIME      access-time tracking off, so access data cannot be trusted
          EMPTY         no bytes and no files
          IMMEDIATE     older than ImmediateYears (see RequirePerFileProof)
          CANDIDATE     older than CandidateYears — needs approval
          ACTIVE        touched inside CandidateYears
          REVIEW        evidence incomplete or contradictory — look by hand
    #>
    [CmdletBinding()]
    param(
        [PSCustomObject]$Volume,
        [PSCustomObject]$Analytics,
        [PSCustomObject]$PerFile,
        [int]$CandidateYears = 3,
        [int]$ImmediateYears = 7,
        [switch]$RequirePerFileProof,
        [datetime]$Now = (Get-Date),

        # When this run first touched the cluster. Any access timestamp at or after it was
        # produced BY THIS TOOL: listing a directory updates its own atime on a volume with
        # access_time_enabled. Without this, every path we examine reports "accessed today"
        # and comes back ACTIVE — the assessment destroys the evidence it went to collect.
        # Leave unset to disable the check (offline tests supply fixed timestamps).
        [AllowNull()][Nullable[datetime]]$ObservationStart
    )

    $reasons = [System.Collections.Generic.List[string]]::new()

    if (-not $Volume) {
        return [PSCustomObject]@{ Verdict = 'REVIEW'; Reasons = @('Volume could not be resolved.'); YearsIdle = $null; IsLowerBound = $null }
    }

    if ($Volume.AnalyticsSupported -eq $false) {
        $reasons.Add("FSA not supported on volume '$($Volume.Name)'.")
        return [PSCustomObject]@{ Verdict = 'NO_ANALYTICS'; Reasons = $reasons; YearsIdle = $null; IsLowerBound = $null }
    }
    # Checked FIRST, ahead of the scan-state guards: a path that does not exist is a settled fact
    # whatever the scan is doing. Waiting for analytics on an absent directory is waiting forever.
    if ($Analytics -and $Analytics.PSObject.Properties.Name -contains 'PathMissing' -and $Analytics.PathMissing) {
        $reasons.Add('The target path does not exist on the volume (REST 404) — nothing left to delete.')
        return [PSCustomObject]@{ Verdict = 'GONE'; Reasons = $reasons; YearsIdle = $null; IsLowerBound = $null }
    }

    if ($Volume.AnalyticsState -and $Volume.AnalyticsState -ne 'on') {
        $reasons.Add("FSA state is '$($Volume.AnalyticsState)' on volume '$($Volume.Name)' — enable it and let the scan finish.")
        return [PSCustomObject]@{ Verdict = 'NO_ANALYTICS'; Reasons = $reasons; YearsIdle = $null; IsLowerBound = $null }
    }
    if ($Volume.AnalyticsInitState -and $Volume.AnalyticsInitState -notin @('complete', 'successful')) {
        $reasons.Add("FSA initialization state is '$($Volume.AnalyticsInitState)' — data is incomplete until the scan finishes.")
        return [PSCustomObject]@{ Verdict = 'NO_ANALYTICS'; Reasons = $reasons; YearsIdle = $null; IsLowerBound = $null }
    }
    if (-not $Analytics) {
        $reasons.Add('No analytics returned for the target path.')
        return [PSCustomObject]@{ Verdict = 'NO_ANALYTICS'; Reasons = $reasons; YearsIdle = $null; IsLowerBound = $null }
    }

    # EMPTY requires POSITIVE evidence of zero, never absent data. Treating null as empty made a
    # failed analytics read look like "nothing here" — and since EMPTY is deletable by default,
    # a broken read presented as "safe to delete everything". Missing numbers are NO_ANALYTICS.
    if (-not $Analytics.HasData -or $null -eq $Analytics.BytesUsed -or $null -eq $Analytics.FileCount) {
        $reasons.Add('Analytics returned no bytes_used/file_count for this path — cannot tell empty from unmeasured.')
        return [PSCustomObject]@{ Verdict = 'NO_ANALYTICS'; Reasons = $reasons; YearsIdle = $null; IsLowerBound = $null }
    }

    if ($Analytics.IncompleteData -eq $true) {
        $reasons.Add('FSA reports incomplete_data for this path — the scan has not fully covered it.')
        return [PSCustomObject]@{ Verdict = 'NO_ANALYTICS'; Reasons = $reasons; YearsIdle = $null; IsLowerBound = $null }
    }

    # An empty directory is NOT zero bytes. FSA reports the directory inode's own footprint —
    # 4096 bytes for one qtree, 20480 for another, both verified by direct listing to hold 0 entries.
    # Testing BytesUsed -eq 0 therefore never fired, and those targets fell through to the
    # histogram, where the only bucket is that same inode with an access time of THIS WEEK
    # (our own listing touched it) — so a provably empty qtree came back ACTIVE.
    #
    # File and subdirectory counts are the honest test: no files and no subdirectories means
    # nothing is stored here, whatever the inode weighs.
    if ([int64]$Analytics.FileCount -eq 0 -and [int64]$Analytics.SubdirCount -eq 0) {
        $reasons.Add("Target holds no files and no subdirectories (measured). " +
                     "BytesUsed $($Analytics.BytesUsed) is the directory inode itself, not content.")
        return [PSCustomObject]@{ Verdict = 'EMPTY'; Reasons = $reasons; YearsIdle = $null; IsLowerBound = $false }
    }

    $acc = Get-NaBucketSummary -Buckets $Analytics.Buckets -Dimension 'Accessed' -Now $Now
    $mod = Get-NaBucketSummary -Buckets $Analytics.Buckets -Dimension 'Modified' -Now $Now

    if ($acc.UnparsedLabels) { $reasons.Add("Unrecognised access-time bucket labels: $($acc.UnparsedLabels -join ', ')") }
    if ($mod.UnparsedLabels) { $reasons.Add("Unrecognised modify-time bucket labels: $($mod.UnparsedLabels -join ', ')") }

    if ($Volume.AccessTimeEnabled -eq $false) {
        $reasons.Add("access_time_enabled is false on volume '$($Volume.Name)' — access data is unreliable; decide on modify time only.")
        if (-not $mod.HasData) {
            return [PSCustomObject]@{ Verdict = 'NO_ATIME'; Reasons = $reasons; YearsIdle = $null; IsLowerBound = $null }
        }
        $years = $mod.YearsSinceNewest
        $lower = $mod.IsLowerBound
        $verdictBase = 'NO_ATIME'
    }
    else {
        if (-not $acc.HasData -and -not $mod.HasData) {
            $reasons.Add('Histograms contain no datable non-empty buckets.')
            return [PSCustomObject]@{ Verdict = 'REVIEW'; Reasons = $reasons; YearsIdle = $null; IsLowerBound = $null }
        }
        # "No access AND no new files" — the binding constraint is whichever was touched
        # most recently, so take the smaller idle age.
        $candidates = @(@($acc.YearsSinceNewest, $mod.YearsSinceNewest) | Where-Object { $null -ne $_ })
        $years = $null
        foreach ($c in $candidates) { if ($null -eq $years -or $c -lt $years) { $years = $c } }
        $lower = [bool]($acc.IsLowerBound -and $mod.IsLowerBound)
        $verdictBase = $null
    }

    $reasons.Add("Newest access bucket: $($acc.NewestLabel ?? 'n/a'); newest modify bucket: $($mod.NewestLabel ?? 'n/a').")
    if ($acc.UnknownBytes -gt 0) { $reasons.Add("$([math]::Round($acc.UnknownBytes/1GB,2)) GB sits in the 'unknown' access bucket.") }

    $histYears = $years
    $histLower = $lower

    # ---- Per-file evidence -------------------------------------------------------------
    # Read the real timestamps FIRST, before any verdict is formed. Doing this only after the
    # histogram had already reached IMMEDIATE made IMMEDIATE unreachable in practice: a
    # collapsed oldest bucket ("2022 or OLDER") caps the measurable histogram age just past
    # the collapse boundary, which is nowhere near a 7-year bar.
    $proofYears = $null
    $proofUsable = $false

    if ($PerFile) {
        if (-not $PerFile.Complete) {
            $reasons.Add("Per-file walk was incomplete ($($PerFile.Notes -join ' ')) — not accepted as proof.")
        }
        else {
            $stamps = @(@($PerFile.NewestAccessed, $PerFile.NewestModified) | Where-Object { $_ })
            if (-not $stamps) {
                $reasons.Add('Per-file walk returned no timestamps — not accepted as proof.')
            }
            else {
                $newest = $stamps[0]
                foreach ($s in $stamps) { if ($s -gt $newest) { $newest = $s } }
                $proofYears = [math]::Round(($Now - $newest).TotalDays / 365.25, 2)
                $proofUsable = $true
                $reasons.Add("Per-file proof: newest timestamp $($newest.ToString('yyyy-MM-dd')) ($proofYears years), from $($PerFile.FilesSeen) file(s) across $($PerFile.DirsVisited) directory(ies).")
            }
        }
    }

    # ---- Reconcile the two sources ------------------------------------------------------
    # Newer evidence always wins: if real timestamps show recent activity the histogram missed,
    # trust that and back off. In the other direction, proof may only EXTEND the age when the
    # histogram age was a lower bound (collapsed bucket) — where the histogram is exact there
    # is no reason to override it, and doing so would let a bounded walk argue past real data.
    if ($proofUsable) {
        if ($proofYears -lt $years) {
            $years = $proofYears
            $lower = $false
            $reasons.Add('Per-file evidence is newer than the histogram suggested — using the per-file age.')
        }
        elseif ($histLower) {
            $years = $proofYears
            $lower = $false
            $reasons.Add("Histogram age was a lower bound ($histYears y, collapsed oldest bucket); refined to $proofYears y from real timestamps.")
        }
        else {
            $reasons.Add("Histogram age ($histYears y) is exact — per-file age ($proofYears y) not used to extend it.")
        }
    }

    $verdict = if ($years -ge $ImmediateYears) { 'IMMEDIATE' }
               elseif ($years -ge $CandidateYears) { 'CANDIDATE' }
               else { 'ACTIVE' }

    # A collapsed oldest bucket cannot establish the long threshold on its own, so immediate
    # deletion is withheld until real timestamps back it up.
    if ($verdict -eq 'IMMEDIATE' -and $RequirePerFileProof -and -not $proofUsable) {
        $verdict = 'CANDIDATE'
        $reasons.Add("Meets the $ImmediateYears-year bar on histogram data alone, but per-file proof is required and was not available — held at CANDIDATE.")
    }

    if ($verdictBase -eq 'NO_ATIME' -and $verdict -eq 'IMMEDIATE') {
        $verdict = 'CANDIDATE'
        $reasons.Add('Immediate deletion withheld because access-time tracking is disabled.')
    }

    [PSCustomObject]@{
        Verdict          = $verdict
        YearsIdle        = $years
        IsLowerBound     = $lower
        AccessedSummary  = $acc
        ModifiedSummary  = $mod
        PerFile          = $PerFile
        Reasons          = $reasons
    }
}

Export-ModuleMember -Function @(
    'Get-NaRestContext',
    'Invoke-NaRest',
    'Get-NaVolume',
    'Get-NaVolumeList',
    'Remove-NaDirectory',
    'Get-NaDirectoryEntries',
    'Find-NaDFSContainerVolumes',
    'Resolve-NaSymlinkChain',
    'Get-DFSAnomaly',
    'Get-DFSSubPathSuffix',
    'Get-DFSDeleteClassification',
    'Enable-NaVolumeAnalytics',
    'ConvertFrom-NaTimeLabel',
    'Get-NaDirectoryAnalytics',
    'Get-NaBucketSummary',
    'Get-NaNewestTimestamp',
    'Get-DFSCleanupVerdict'
)
