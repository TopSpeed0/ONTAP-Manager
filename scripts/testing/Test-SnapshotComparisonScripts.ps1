<#
.SYNOPSIS
    Offline tests for the snapshot comparison workflow — no cluster connection required.

.DESCRIPTION
    Exercises the whole collection-to-report path against fixtures captured from a live
    ONTAP 9 cluster's `vol snapshot show` output (sanitised names, identical wire format):

      1. every file parses and the module exports what the driver calls
      2. the ONTAP command builder only emits `vol snapshot show`, and rejects invented fields
      3. size and creation-time parsing, including ONTAP's double-space single-digit day
      4. the CSV parser is header-driven (ONTAP reorders columns) and banner-tolerant
      5. the ranking / threshold engine buckets oldest, largest, and candidates correctly
      6. an unmeasured snapshot is never treated as 0 bytes or 0 days old
      7. end to end: raw capture -> parse -> rank -> CSV reports on disk, via the real
         driver script in -ReplayFrom mode
      8. nothing in either file can delete or modify a snapshot

    Run this after any change to Get-SnapshotInventory.psm1 or Get-SnapshotComparison.ps1.

.EXAMPLE
    .\scripts\testing\Test-SnapshotComparisonScripts.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot    = (Resolve-Path (Join-Path $ScriptDir '..\..')).Path
$SnapDir     = Join-Path $RepoRoot 'scripts\snapshots'
$ModulePath  = Join-Path $SnapDir 'Get-SnapshotInventory.psm1'
$DriverPath  = Join-Path $SnapDir 'Get-SnapshotComparison.ps1'
$FixtureDir  = Join-Path $ScriptDir 'fixtures\snapshots'

# Every age/threshold assertion below is relative to this instant, never to Get-Date.
$now = [datetime]'2026-07-30 18:00:00'

$pass = 0; $fail = 0
function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        $result = & $Body
        if ($result -eq $true) {
            Write-Host "  PASS  $Name" -ForegroundColor Green
            $script:pass++
        }
        else {
            Write-Host "  FAIL  $Name -> $result" -ForegroundColor Red
            $script:fail++
        }
    }
    catch {
        Write-Host "  FAIL  $Name -> $($_.Exception.Message)" -ForegroundColor Red
        $script:fail++
    }
}

Write-Host "`n=== 1. Syntax ===" -ForegroundColor Cyan
foreach ($f in @($ModulePath, $DriverPath)) {
    Test-Case "parses: $(Split-Path -Leaf $f)" {
        if (-not (Test-Path -LiteralPath $f)) { return 'missing file' }
        $errs = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$errs)
        if ($errs) { return ($errs | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) -join '; ' }
        return $true
    }
}

Write-Host "`n=== 2. Module surface ===" -ForegroundColor Cyan
Import-Module $ModulePath -Force
foreach ($fn in @('Get-OntapSnapshotFieldCatalog', 'Get-SnapshotInventoryCommand',
                  'Convert-OntapSize', 'Format-SnapshotBytes', 'Convert-OntapSnapshotTime',
                  'ConvertFrom-OntapSnapshotCsv', 'ConvertTo-SnapshotRecord',
                  'Get-SnapshotReportSet')) {
    Test-Case "exported: $fn" { [bool](Get-Command $fn -ErrorAction SilentlyContinue) }
}

Write-Host "`n=== 3. ONTAP command builder ===" -ForegroundColor Cyan

Test-Case 'default command is vol snapshot show with row 0' {
    $c = Get-SnapshotInventoryCommand
    if ($c -notmatch 'vol snapshot show -fields ') { return "no show command: $c" }
    # Without `row 0` ONTAP emits an interactive pager prompt and truncates the output.
    if ($c -notmatch '\brow 0\b') { return 'row 0 missing — output would be paged and truncated' }
    if ($c -notmatch "showseparator ','") { return 'separator not set' }
    return $true
}

Test-Case 'every default field is one ONTAP actually accepts' {
    $catalog = Get-OntapSnapshotFieldCatalog
    $fields  = ([regex]::Match((Get-SnapshotInventoryCommand), '-fields ([^\s]+)').Groups[1].Value) -split ','
    $bad = @($fields | Where-Object { $_ -notin $catalog })
    if ($bad) { return "not in the ONTAP field catalog: $($bad -join ', ')" }
    # Age and size ranking are the whole point — these two must be collected.
    foreach ($needed in @('create-time', 'size', 'vserver', 'volume', 'snapshot')) {
        if ($fields -notcontains $needed) { return "missing required field: $needed" }
    }
    return $true
}

Test-Case 'an invented field is refused, not silently sent to the cluster' {
    try {
        $null = Get-SnapshotInventoryCommand -Fields @('vserver', 'snapshot-size-bytes')
        return 'accepted a field that does not exist'
    }
    catch { return ($_.Exception.Message -match 'not valid') }
}

Test-Case 'catalog matches what the cluster reported for -fields ?' {
    # Spot-check against the live `vol snapshot show -fields ?` output captured 2026-07-30.
    $catalog = Get-OntapSnapshotFieldCatalog
    foreach ($f in @('create-time', 'size', 'owners', 'busy', 'snapmirror-label', 'state',
                     'expiry-time', 'logical-used', 'reserved-size')) {
        if ($catalog -notcontains $f) { return "catalog missing real field: $f" }
    }
    # Names that look plausible but are NOT ONTAP fields must be absent.
    foreach ($f in @('creation-time', 'snapshot-size', 'used', 'age')) {
        if ($catalog -contains $f) { return "catalog contains invented field: $f" }
    }
    return $true
}

Test-Case 'SVM and volume filters are appended as ONTAP flags' {
    $c = Get-SnapshotInventoryCommand -Svm 'svm_alpha' -Volume 'bigdata'
    ($c -match '-vserver svm_alpha') -and ($c -match '-volume bigdata')
}

Write-Host "`n=== 4. Size parsing ===" -ForegroundColor Cyan

Test-Case 'ONTAP size strings convert to bytes' {
    $cases = @{
        '2.26GB'   = [int64][math]::Round(2.26D * 1073741824D)
        '17.04MB'  = [int64][math]::Round(17.04D * 1048576D)
        '148KB'    = 151552
        '1.75TB'   = [int64][math]::Round(1.75D * 1099511627776D)
        '870.5GB'  = [int64][math]::Round(870.5D * 1073741824D)
        '512B'     = 512
        '4096'     = 4096
    }
    foreach ($k in $cases.Keys) {
        $got = Convert-OntapSize $k
        if ($got -ne $cases[$k]) { return "'$k' -> $got, expected $($cases[$k])" }
    }
    return $true
}

Test-Case 'SAFETY an absent size is $null, never 0' {
    # 0 would sort as "smallest" and quietly vanish from every largest-N ranking while
    # still looking like a real measurement.
    foreach ($v in @('-', '', '   ', $null, 'n/a', 'lots')) {
        $got = Convert-OntapSize $v
        if ($null -ne $got) { return "'$v' -> $got, expected null" }
    }
    return $true
}

Test-Case 'byte formatting round-trips into human units' {
    if ((Format-SnapshotBytes 1099511627776) -ne '1.00 TB') { return (Format-SnapshotBytes 1099511627776) }
    if ((Format-SnapshotBytes 151552) -ne '148.00 KB')      { return (Format-SnapshotBytes 151552) }
    if ((Format-SnapshotBytes 512) -ne '512 B')             { return (Format-SnapshotBytes 512) }
    if ((Format-SnapshotBytes $null) -ne '')                { return 'null should format as empty, not 0' }
    return $true
}

Write-Host "`n=== 5. Creation-time parsing ===" -ForegroundColor Cyan

Test-Case "ONTAP's ctime format parses" {
    $d = Convert-OntapSnapshotTime 'Wed Jul 29 00:00:18 2026'
    if ($null -eq $d) { return 'returned null' }
    ($d.Year -eq 2026) -and ($d.Month -eq 7) -and ($d.Day -eq 29) -and ($d.Hour -eq 0) -and ($d.Second -eq 18)
}

Test-Case 'REGRESSION single-digit day is double-spaced by ONTAP and still parses' {
    # "Sun Dec  1 02:00:00 2019" — two spaces. A parser that assumes one space returns null,
    # which would drop the oldest snapshots out of the oldest report entirely.
    $d = Convert-OntapSnapshotTime 'Sun Dec  1 02:00:00 2019'
    if ($null -eq $d) { return 'returned null for a double-spaced day' }
    ($d.Year -eq 2019) -and ($d.Month -eq 12) -and ($d.Day -eq 1)
}

Test-Case 'the double quotes ONTAP wraps the timestamp in are stripped' {
    $d = Convert-OntapSnapshotTime '"Mon Mar 16 13:15:37 2026"'
    ($null -ne $d) -and ($d.Day -eq 16)
}

Test-Case 'SAFETY an unparseable timestamp is $null, never now and never epoch' {
    foreach ($v in @('-', '', '   ', $null, 'not-a-date')) {
        $got = Convert-OntapSnapshotTime $v
        if ($null -ne $got) { return "'$v' -> $got, expected null" }
    }
    return $true
}

Write-Host "`n=== 6. Raw output parsing ===" -ForegroundColor Cyan

$rawA = @(Get-Content -LiteralPath (Join-Path $FixtureDir 'ClusterA.txt'))
$rawB = @(Get-Content -LiteralPath (Join-Path $FixtureDir 'ClusterB.txt'))
$rawE = @(Get-Content -LiteralPath (Join-Path $FixtureDir 'EmptyResult.txt'))

Test-Case 'ClusterA fixture yields 9 rows and 1 rejected row' {
    $errs = $null
    $rows = @(ConvertFrom-OntapSnapshotCsv -Lines $rawA -ParseErrors ([ref]$errs))
    if ($rows.Count -ne 9) { return "rows=$($rows.Count), expected 9" }
    if (@($errs).Count -ne 1) { return "parse errors=$(@($errs).Count), expected 1 (the truncated row)" }
    if (@($errs)[0].Reason -notmatch 'column count') { return "wrong rejection reason: $(@($errs)[0].Reason)" }
    return $true
}

Test-Case "REGRESSION the display-name row is not accepted as a snapshot" {
    # ONTAP prints the field names, then a human header ("Snapshot Size"). Skipping a fixed
    # number of banner lines lets that header row through as a snapshot called 'Snapshot'.
    $rows = @(ConvertFrom-OntapSnapshotCsv -Lines $rawA)
    $bogus = @($rows | Where-Object { $_.snapshot -eq 'Snapshot' -or $_.vserver -eq 'Vserver' })
    if ($bogus.Count) { return 'the display-name header row was parsed as data' }
    return $true
}

Test-Case 'REGRESSION a short banner does not cost the first data row' {
    # ClusterA has a 9-line preamble, ClusterB a 7-line one. Anything that skips a fixed
    # count (the repo`s Invoke-OntapCsv uses awk NR>8) loses a real snapshot on one of them.
    $rows = @(ConvertFrom-OntapSnapshotCsv -Lines $rawB)
    if ($rows.Count -ne 3) { return "rows=$($rows.Count), expected 3" }
    if (@($rows | Where-Object { $_.snapshot -eq 'daily.2026-07-25' }).Count -ne 1) {
        return 'the first data row was swallowed by the banner skip'
    }
    return $true
}

Test-Case 'REGRESSION columns are mapped by field name, not by position' {
    # ONTAP returns fields in ITS order, not the requested one. ClusterA comes back
    # ...create-time,busy,owners,size... while ClusterB comes back ...size,create-time,state...
    # A positional parser reads ClusterB's size as a timestamp and vice versa.
    $rows = @(ConvertFrom-OntapSnapshotCsv -Lines $rawB)
    $r = $rows | Where-Object { $_.snapshot -eq 'daily.2026-07-25' }
    if ($r.size -ne '412.8GB') { return "size='$($r.size)' — read from the wrong column" }
    if ($r.'create-time' -notmatch 'Jul 25 02:00:00 2026') { return "create-time='$($r.'create-time')'" }
    if ($r.'snapmirror-label' -ne 'daily') { return "label='$($r.'snapmirror-label')'" }
    return $true
}

Test-Case "ONTAP's '-' placeholder becomes null, not the literal dash" {
    $rows = @(ConvertFrom-OntapSnapshotCsv -Lines $rawA)
    $r = $rows | Where-Object { $_.snapshot -eq 'nightly.1' }
    ($null -eq $r.owners) -and ($null -eq $r.state) -and ($null -eq $r.'snapmirror-label')
}

Test-Case 'a quoted multi-word owner survives parsing' {
    $rows = @(ConvertFrom-OntapSnapshotCsv -Lines $rawA)
    $r = $rows | Where-Object { $_.snapshot -eq 'clone_base.2026-03-16' }
    ($r.owners -eq 'volume clone') -and ($r.busy -eq 'true')
}

Test-Case 'an empty ONTAP result is 0 rows and 0 errors, not an error storm' {
    $errs = $null
    $rows = @(ConvertFrom-OntapSnapshotCsv -Lines $rawE -ParseErrors ([ref]$errs))
    if ($rows.Count -ne 0) { return "rows=$($rows.Count)" }
    if (@($errs).Count -ne 0) { return "errors=$(@($errs).Count): $((@($errs) | ForEach-Object Reason) -join '; ')" }
    return $true
}

Test-Case 'no input is handled without throwing' {
    $rows = @(ConvertFrom-OntapSnapshotCsv -Lines @())
    $rows.Count -eq 0
}

Write-Host "`n=== 7. Record normalisation ===" -ForegroundColor Cyan

$recsA = @(ConvertFrom-OntapSnapshotCsv -Lines $rawA | ConvertTo-SnapshotRecord -Cluster 'ClusterA' -ClusterName 'cl-a' -Now $now)
$recsB = @(ConvertFrom-OntapSnapshotCsv -Lines $rawB | ConvertTo-SnapshotRecord -Cluster 'ClusterB' -ClusterName 'cl-b' -Now $now)
$allRecs = @($recsA + $recsB)

Test-Case 'records carry cluster, SVM, volume, snapshot, time, age and size' {
    if ($allRecs.Count -ne 12) { return "records=$($allRecs.Count), expected 12" }
    $r = $allRecs | Where-Object { $_.Snapshot -eq 'yearly.2019' }
    if ($r.Cluster -ne 'ClusterA')  { return "Cluster=$($r.Cluster)" }
    if ($r.ClusterName -ne 'cl-a')  { return "ClusterName=$($r.ClusterName)" }
    if ($r.Svm -ne 'svm_alpha')     { return "Svm=$($r.Svm)" }
    if ($r.Volume -ne 'archive1')   { return "Volume=$($r.Volume)" }
    if ($r.CreateTime.Year -ne 2019) { return "CreateTime=$($r.CreateTime)" }
    if ($r.SizeBytes -ne [int64][math]::Round(870.5D * 1073741824D)) { return "SizeBytes=$($r.SizeBytes)" }
    return $true
}

Test-Case 'age is computed against the supplied instant, not the wall clock' {
    $r = $allRecs | Where-Object { $_.Snapshot -eq 'nightly.1' }
    # 2026-07-29 00:00:18 -> 2026-07-30 18:00:00
    $expected = [math]::Round(($now - ([datetime]'2026-07-29 00:00:18')).TotalDays, 2)
    if ($r.AgeDays -ne $expected) { return "AgeDays=$($r.AgeDays), expected $expected" }
    return $true
}

Test-Case 'SAFETY a snapshot with no size has SizeBytes null, not 0' {
    $r = $allRecs | Where-Object { $_.Snapshot -eq 'no_size_snap' }
    if ($null -ne $r.SizeBytes) { return "SizeBytes=$($r.SizeBytes)" }
    if ($r.SizeDisplay -ne '')  { return "SizeDisplay='$($r.SizeDisplay)' — should be blank" }
    return $true
}

Test-Case 'SAFETY a snapshot with no create-time has AgeDays null, not 0' {
    $r = $allRecs | Where-Object { $_.Snapshot -eq 'no_date_snap' }
    ($null -eq $r.CreateTime) -and ($null -eq $r.AgeDays)
}

Test-Case 'busy / owned snapshots are flagged as locked with a reason' {
    $clone = $allRecs | Where-Object { $_.Snapshot -eq 'clone_base.2026-03-16' }
    if (-not $clone.Locked) { return 'volume-clone owner not flagged' }
    if ($clone.LockReason -notmatch 'busy') { return "LockReason=$($clone.LockReason)" }
    if ($clone.LockReason -notmatch 'volume clone') { return "LockReason=$($clone.LockReason)" }
    $free = $allRecs | Where-Object { $_.Snapshot -eq 'hourly.0' }
    if ($free.Locked) { return 'an unowned, not-busy snapshot was flagged locked' }
    return $true
}

Write-Host "`n=== 8. Ranking and thresholds ===" -ForegroundColor Cyan

$set = Get-SnapshotReportSet -Records $allRecs -AgeDays 90 -LargeThresholdBytes 107374182400 `
        -TopOldest 50 -TopLargest 50 -Now $now

Test-Case 'stats separate measured from unmeasured records' {
    $s = $set.Stats
    if ($s.Total -ne 12)          { return "Total=$($s.Total)" }
    if ($s.Clusters -ne 2)        { return "Clusters=$($s.Clusters)" }
    if ($s.WithSize -ne 11)       { return "WithSize=$($s.WithSize)" }
    if ($s.WithCreateTime -ne 11) { return "WithCreateTime=$($s.WithCreateTime)" }
    if ($s.SizeUnknown -ne 1)     { return "SizeUnknown=$($s.SizeUnknown)" }
    if ($s.DateUnknown -ne 1)     { return "DateUnknown=$($s.DateUnknown)" }
    if ($s.Locked -ne 2)          { return "Locked=$($s.Locked)" }
    return $true
}

Test-Case 'oldest is ranked across clusters, oldest first' {
    $o = $set.Oldest
    if ($o[0].Snapshot -ne 'ancient.2018')  { return "rank1=$($o[0].Snapshot)" }
    if ($o[0].Cluster  -ne 'ClusterB')      { return "rank1 cluster=$($o[0].Cluster)" }
    if ($o[1].Snapshot -ne 'yearly.2019')   { return "rank2=$($o[1].Snapshot)" }
    if ($o[0].Rank -ne 1 -or $o[1].Rank -ne 2) { return 'ranks not assigned 1..n' }
    if (@($o).Count -ne 11) { return "oldest count=$(@($o).Count), expected 11 dated records" }
    return $true
}

Test-Case 'largest is ranked across clusters, biggest first' {
    $l = $set.Largest
    if ($l[0].Snapshot -ne 'ancient.2018')   { return "rank1=$($l[0].Snapshot)" }
    if ($l[1].Snapshot -ne 'weekly.2025-01') { return "rank2=$($l[1].Snapshot)" }
    if ($l[2].Snapshot -ne 'yearly.2019')    { return "rank3=$($l[2].Snapshot)" }
    if ($l[3].Snapshot -ne 'daily.2026-07-25') { return "rank4=$($l[3].Snapshot)" }
    return $true
}

Test-Case 'SAFETY unmeasured records are excluded from rankings, not ranked as smallest/newest' {
    if (@($set.Largest | Where-Object { $_.Snapshot -eq 'no_size_snap' }).Count) {
        return 'a snapshot with no size appears in the largest ranking'
    }
    if (@($set.Oldest | Where-Object { $_.Snapshot -eq 'no_date_snap' }).Count) {
        return 'a snapshot with no create-time appears in the oldest ranking'
    }
    return $true
}

Test-Case 'unmeasured records are surfaced, not dropped' {
    $u = @($set.Unknown)
    if ($u.Count -ne 2) { return "Unknown=$($u.Count), expected 2" }
    $names = @($u | ForEach-Object { $_.Snapshot })
    if ($names -notcontains 'no_size_snap') { return "missing no_size_snap: $($names -join ', ')" }
    if ($names -notcontains 'no_date_snap') { return "missing no_date_snap: $($names -join ', ')" }
    if (($u | Where-Object { $_.Snapshot -eq 'no_size_snap' }).Why -notmatch 'size') { return 'no reason recorded' }
    return $true
}

Test-Case 'age threshold selects exactly the snapshots at or over it' {
    $c = @($set.OldCandidates)
    if ($c.Count -ne 5) { return "count=$($c.Count) ($(($c | ForEach-Object Snapshot) -join ', ')), expected 5" }
    foreach ($r in $c) { if ($r.AgeDays -lt 90) { return "$($r.Snapshot) is only $($r.AgeDays) d old" } }
    if (@($c | Where-Object { $_.Snapshot -eq 'daily.2026-07-25' }).Count) { return 'a 5-day-old snapshot was called old' }
    return $true
}

Test-Case 'size threshold selects exactly the snapshots at or over it' {
    $c = @($set.LargeCandidates)
    if ($c.Count -ne 4) { return "count=$($c.Count) ($(($c | ForEach-Object Snapshot) -join ', ')), expected 4" }
    foreach ($r in $c) { if ($r.SizeBytes -lt 107374182400) { return "$($r.Snapshot) is only $($r.SizeDisplay)" } }
    if (@($c | Where-Object { $_.Snapshot -eq 'clone_base.2026-03-16' }).Count) { return 'a 5.48 GB snapshot was called large' }
    return $true
}

Test-Case 'thresholds are configurable, not baked in' {
    $tight = Get-SnapshotReportSet -Records $allRecs -AgeDays 3000 -LargeThresholdBytes 1099511627776 -Now $now
    if (@($tight.OldCandidates).Count -ne 1) { return "AgeDays 3000 -> $(@($tight.OldCandidates).Count), expected 1" }
    if (@($tight.LargeCandidates).Count -ne 2) { return "1 TB -> $(@($tight.LargeCandidates).Count), expected 2" }
    return $true
}

Test-Case 'top-N caps the ranking reports' {
    $capped = Get-SnapshotReportSet -Records $allRecs -TopOldest 3 -TopLargest 2 -Now $now
    if (@($capped.Oldest).Count -ne 3)  { return "Oldest=$(@($capped.Oldest).Count)" }
    if (@($capped.Largest).Count -ne 2) { return "Largest=$(@($capped.Largest).Count)" }
    # Capping the rankings must not shrink the all-records report.
    if (@($capped.All).Count -ne 12)    { return "All=$(@($capped.All).Count)" }
    return $true
}

Test-Case 'per-cluster summary compares clusters side by side' {
    $s = @($set.ClusterSummary)
    if ($s.Count -ne 2) { return "clusters=$($s.Count)" }
    $a = $s | Where-Object { $_.Cluster -eq 'ClusterA' }
    $b = $s | Where-Object { $_.Cluster -eq 'ClusterB' }
    if ($a.Snapshots -ne 9) { return "ClusterA snapshots=$($a.Snapshots)" }
    if ($b.Snapshots -ne 3) { return "ClusterB snapshots=$($b.Snapshots)" }
    if ($a.Volumes -ne 5)   { return "ClusterA volumes=$($a.Volumes)" }
    if ($b.Volumes -ne 2)   { return "ClusterB volumes=$($b.Volumes)" }
    if ($a.SizeUnknown -ne 1) { return "ClusterA SizeUnknown=$($a.SizeUnknown)" }
    if ($b.OldestSnapshot -notmatch 'ancient.2018') { return "ClusterB oldest=$($b.OldestSnapshot)" }
    # A cluster total must only sum measured sizes.
    $expectedB = (Convert-OntapSize '412.8GB') + (Convert-OntapSize '2.10TB') + (Convert-OntapSize '88KB')
    if ($b.TotalBytes -ne $expectedB) { return "ClusterB TotalBytes=$($b.TotalBytes), expected $expectedB" }
    return $true
}

Test-Case 'an empty record set does not throw' {
    $e = Get-SnapshotReportSet -Records @() -Now $now
    ($e.Stats.Total -eq 0) -and (@($e.Oldest).Count -eq 0) -and (@($e.ClusterSummary).Count -eq 0)
}

Write-Host "`n=== 9. End to end via the real driver (ReplayFrom, no cluster) ===" -ForegroundColor Cyan

$replaySrc = Join-Path ([IO.Path]::GetTempPath()) ("snapcmp-src-" + [guid]::NewGuid().ToString('N'))
$replayOut = Join-Path ([IO.Path]::GetTempPath()) ("snapcmp-out-" + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path (Join-Path $replaySrc 'raw') -Force
Copy-Item -LiteralPath (Join-Path $FixtureDir 'ClusterA.txt') -Destination (Join-Path $replaySrc 'raw\ClusterA.txt')
Copy-Item -LiteralPath (Join-Path $FixtureDir 'ClusterB.txt') -Destination (Join-Path $replaySrc 'raw\ClusterB.txt')

$driverOutput = $null
$driverFailed = $null
try {
    # *>&1, not 2>&1: the driver reports progress with Write-Host, which goes to the
    # information stream. Capturing only success+error streams misses all of it.
    $driverOutput = & $DriverPath -ReplayFrom $replaySrc -OutputPath $replayOut `
        -AgeDays 90 -LargeThresholdGB 100 -TopOldest 50 -TopLargest 50 *>&1 | Out-String
}
catch {
    $driverFailed = $_.Exception.Message
}

Test-Case 'the driver completes in replay mode without touching a cluster' {
    if ($driverFailed) { return "driver threw: $driverFailed" }
    if ($driverOutput -notmatch 'REPLAY mode') { return 'replay banner not shown' }
    if ($driverOutput -notmatch 'Read-only run') { return "driver did not reach the end:`n$driverOutput" }
    return $true
}

Test-Case 'every report file is written to disk' {
    foreach ($f in @('snapshots-all.csv', 'snapshots-oldest.csv', 'snapshots-largest.csv',
                     'snapshots-old-candidates.csv', 'snapshots-large-candidates.csv',
                     'snapshots-unknown.csv', 'cluster-summary.csv', 'snapshots.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $replayOut $f))) { return "missing report: $f" }
    }
    return $true
}

Test-Case 'the all-records CSV holds every snapshot with the identifying columns' {
    $csv = @(Import-Csv -LiteralPath (Join-Path $replayOut 'snapshots-all.csv'))
    if ($csv.Count -ne 12) { return "rows=$($csv.Count), expected 12" }
    foreach ($col in @('Cluster', 'Svm', 'Volume', 'Snapshot', 'CreateTime', 'AgeDays',
                       'SizeBytes', 'SizeDisplay', 'Locked')) {
        if ($csv[0].PSObject.Properties.Name -notcontains $col) { return "missing column: $col" }
    }
    return $true
}

Test-Case 'the oldest and largest CSVs are ranked as the engine ranked them' {
    $o = @(Import-Csv -LiteralPath (Join-Path $replayOut 'snapshots-oldest.csv'))
    $l = @(Import-Csv -LiteralPath (Join-Path $replayOut 'snapshots-largest.csv'))
    if ($o[0].Snapshot -ne 'ancient.2018') { return "oldest rank1=$($o[0].Snapshot)" }
    if ($o[0].Rank -ne '1')                { return "oldest rank column=$($o[0].Rank)" }
    if ($l[0].Snapshot -ne 'ancient.2018') { return "largest rank1=$($l[0].Snapshot)" }
    return $true
}

Test-Case 'the candidate CSVs match the configured thresholds' {
    $old = @(Import-Csv -LiteralPath (Join-Path $replayOut 'snapshots-old-candidates.csv'))
    $big = @(Import-Csv -LiteralPath (Join-Path $replayOut 'snapshots-large-candidates.csv'))
    if ($old.Count -ne 5) { return "old candidates=$($old.Count)" }
    if ($big.Count -ne 4) { return "large candidates=$($big.Count)" }
    return $true
}

Test-Case 'the parse rejection is reported in problems.csv, not swallowed' {
    $p = Join-Path $replayOut 'problems.csv'
    if (-not (Test-Path -LiteralPath $p)) { return 'problems.csv not written for the truncated row' }
    $rows = @(Import-Csv -LiteralPath $p)
    if (@($rows | Where-Object { $_.Stage -eq 'parse' -and $_.Detail -match 'column count' }).Count -eq 0) {
        return "no parse problem recorded: $(($rows | ForEach-Object Detail) -join ' | ')"
    }
    return $true
}

Test-Case 'the JSON record set can be re-analysed offline' {
    $j = Get-Content -LiteralPath (Join-Path $replayOut 'snapshots.json') -Raw | ConvertFrom-Json
    if (@($j.Records).Count -ne 12) { return "records=$(@($j.Records).Count)" }
    if ($j.Stats.Total -ne 12)      { return "Stats.Total=$($j.Stats.Total)" }
    if ($j.AgeDaysThreshold -ne 90) { return "AgeDaysThreshold=$($j.AgeDaysThreshold)" }
    return $true
}

Test-Case 'a different threshold on replay changes the candidate reports' {
    $out2 = Join-Path ([IO.Path]::GetTempPath()) ("snapcmp-out2-" + [guid]::NewGuid().ToString('N'))
    $null = & $DriverPath -ReplayFrom $replaySrc -OutputPath $out2 -AgeDays 3000 -LargeThresholdGB 1024 *>&1
    $old = @(Import-Csv -LiteralPath (Join-Path $out2 'snapshots-old-candidates.csv'))
    $big = @(Import-Csv -LiteralPath (Join-Path $out2 'snapshots-large-candidates.csv'))
    Remove-Item -LiteralPath $out2 -Recurse -Force -ErrorAction SilentlyContinue
    if ($old.Count -ne 1) { return "AgeDays 3000 -> $($old.Count) old candidates, expected 1" }
    if ($big.Count -ne 2) { return "1024 GiB -> $($big.Count) large candidates, expected 2" }
    return $true
}

Remove-Item -LiteralPath $replaySrc -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $replayOut -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "`n=== 10. Read-only guarantee ===" -ForegroundColor Cyan

Test-Case 'the builder refuses to emit a mutating snapshot command' {
    # The guard exists so a future edit that adds a delete path fails here first.
    $src = Get-Content -LiteralPath $ModulePath -Raw
    if ($src -notmatch "refusing to emit a mutating command") { return 'no mutating-verb guard' }
    foreach ($v in @('delete', 'create', 'modify', 'restore', 'destroy')) {
        if ($src -notmatch "'$v'") { return "guard does not cover '$v'" }
    }
    return $true
}

Test-Case 'neither file issues a mutating ONTAP snapshot command' {
    foreach ($f in @($ModulePath, $DriverPath)) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$null)
        foreach ($sl in $ast.FindAll({
                    param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst]
                }, $true)) {
            $v = $sl.Value
            if ($v -match '(?i)\b(vol(ume)?\s+)?snapshot\s+(delete|create|modify|rename|restore|autodelete|partial-restore)\b') {
                return "$(Split-Path -Leaf $f) contains a mutating command string: $v"
            }
            if ($v -match '(?i)\b(vol|volume|vserver)\s+(delete|destroy|offline)\b') {
                return "$(Split-Path -Leaf $f) contains a destructive command string: $v"
            }
        }
    }
    return $true
}

Test-Case 'the driver only ever runs the command the builder produced' {
    $src = Get-Content -LiteralPath $DriverPath -Raw
    if ($src -notmatch 'Get-SnapshotInventoryCommand') { return 'driver does not use the validated builder' }
    # No ad-hoc ssh invocation that could carry an arbitrary command.
    if ($src -match '(?m)^\s*ssh\s') { return 'driver shells out to ssh directly, bypassing the builder' }
    return $true
}

Write-Host "`n=== 11. Config-driven targeting ===" -ForegroundColor Cyan

Test-Case 'clusters come from config.json, never a hardcoded list' {
    $src = Get-Content -LiteralPath $DriverPath -Raw
    if ($src -notmatch 'Load-Config\.ps1')          { return 'driver never loads the config' }
    if ($src -notmatch 'Get-OntapTargetClusters')   { return 'driver does not use the config-driven selector' }
    return $true
}

Test-Case 'no IP address, credential or absolute personal path is embedded' {
    foreach ($f in @($ModulePath, $DriverPath, (Join-Path $ScriptDir 'Test-SnapshotComparisonScripts.ps1'))) {
        $src = Get-Content -LiteralPath $f -Raw
        if ($src -match '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b') { return "$(Split-Path -Leaf $f) contains an IP address" }
        if ($src -match '(?i)C:\\Users\\')                        { return "$(Split-Path -Leaf $f) contains an absolute user path" }
        if ($src -match '(?i)(password|passwd)\s*=\s*[''"]')      { return "$(Split-Path -Leaf $f) contains a literal password" }
    }
    return $true
}

Test-Case 'no real cluster name from config.json is embedded in the source' {
    # Names are read from the (gitignored) config.json rather than listed here, so this
    # tracked test file does not itself become the place internal cluster names leak.
    $cfgPath = Join-Path $RepoRoot 'config.json'
    if (-not (Test-Path -LiteralPath $cfgPath)) {
        Write-Host "        (skipped: no config.json in this checkout)" -ForegroundColor DarkGray
        return $true
    }
    $cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
    $names = @($cfg.ONTAP_Clusters | ForEach-Object { $_.cluster; $_.Alias } |
        Where-Object { $_ -and $_.Length -ge 4 })
    foreach ($f in @($ModulePath, $DriverPath, (Join-Path $ScriptDir 'Test-SnapshotComparisonScripts.ps1'))) {
        $src = Get-Content -LiteralPath $f -Raw
        foreach ($n in $names) {
            if ($src -match [regex]::Escape($n)) { return "$(Split-Path -Leaf $f) mentions cluster '$n'" }
        }
    }
    return $true
}

Test-Case 'the -Cluster filter is forwarded to the config-driven selector' {
    $src = Get-Content -LiteralPath $DriverPath -Raw
    if ($src -notmatch "targetArgs\['Cluster'\]") { return '-Cluster is not passed through' }
    if ($src -notmatch "targetArgs\['VIP'\]")     { return '-VIP is not passed through' }
    return $true
}

Test-Case 'REGRESSION Load-Config.ps1 cannot clobber the -Cluster parameter' {
    # Load-Config.ps1's generator loop does `$cluster = $cl.cluster`. PowerShell variable
    # names are case-insensitive, so dot-sourcing it at SCRIPT scope overwrites this
    # script's -Cluster parameter with the last cluster in config.json — `-Cluster <alias>`
    # then silently reports on a different cluster. Observed live before the fix.
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($DriverPath, [ref]$null, [ref]$null)

    $dotSources = @($ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot
    }, $true) | Where-Object { $_.Extent.Text -match 'Load-Config' })

    if ($dotSources.Count -eq 0) { return 'Load-Config.ps1 is never dot-sourced' }

    foreach ($ds in $dotSources) {
        # Walk up: the dot-source must sit inside a function, not directly at script scope.
        $parent = $ds.Parent
        $inFunction = $false
        while ($null -ne $parent) {
            if ($parent -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $inFunction = $true; break }
            $parent = $parent.Parent
        }
        if (-not $inFunction) {
            return "Load-Config.ps1 is dot-sourced at script scope (line $($ds.Extent.StartLineNumber)) — it will overwrite `$Cluster"
        }
    }
    return $true
}

Test-Case 'REGRESSION the config root is not read back from a clobberable variable' {
    # The old code reused $rootDir for both "where config.json lives" and Load-Config's own
    # variable. Reading it back after the dot-source is the same class of bug.
    $src = Get-Content -LiteralPath $DriverPath -Raw
    if ($src -notmatch '\$configRootPath') { return 'no dedicated config-root variable' }
    return $true
}

Test-Case 'the per-cluster SSH helper is used, and its absence is reported not ignored' {
    $src = Get-Content -LiteralPath $DriverPath -Raw
    if ($src -notmatch '"\$\(\$t\.cluster\)-ssh"') { return 'does not build the <cluster>-ssh helper name' }
    if ($src -notmatch 'not defined by Load-Config') { return 'a missing SSH helper is not surfaced' }
    return $true
}

Write-Host "`n=== 12. Script Manager registration (additive) ===" -ForegroundColor Cyan

# The workflow is reachable from the launcher, and adding it must not have cost an existing
# entry — this feature was integrated into a workspace that already had its own local work.
$managerPath = Join-Path $RepoRoot 'scripts\Start-ScriptManager.ps1'
$managerSrc  = if (Test-Path -LiteralPath $managerPath) { Get-Content -LiteralPath $managerPath -Raw } else { $null }
$managerScriptPaths = if ($managerSrc) {
    @([regex]::Matches($managerSrc, "(?m)^\s*Script\s*=\s*'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
} else { @() }

Test-Case 'Start-ScriptManager.ps1 still parses after the additive entry' {
    if (-not $managerSrc) { return "missing file: $managerPath" }
    $errs = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($managerPath, [ref]$null, [ref]$errs)
    if ($errs) { return ($errs | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) -join '; ' }
    return $true
}

Test-Case 'the read-only driver is registered in the Script Manager' {
    if (-not $managerSrc) { return 'no Start-ScriptManager.ps1' }
    if ($managerScriptPaths -notcontains 'scripts\snapshots\Get-SnapshotComparison.ps1') {
        return 'Get-SnapshotComparison.ps1 is not in the $scripts registry'
    }
    # No DefaultArgs: the entry must not pre-seed thresholds or a cluster the operator did not pick.
    if ($managerSrc -notmatch "(?s)Name\s*=\s*'Snapshot Comparison \(read-only\)'.*?DefaultArgs\s*=\s*''") {
        return "the Snapshot Comparison entry does not carry an empty DefaultArgs"
    }
    return $true
}

Test-Case 'the offline test suite is registered too' {
    if ($managerScriptPaths -notcontains 'scripts\testing\Test-SnapshotComparisonScripts.ps1') {
        return 'Test-SnapshotComparisonScripts.ps1 is not in the $scripts registry'
    }
    return $true
}

Test-Case 'every registered script path exists on disk' {
    if (-not $managerScriptPaths.Count) { return 'no Script entries found — the registry regex or the file changed shape' }
    $missing = @($managerScriptPaths | Where-Object { -not (Test-Path -LiteralPath (Join-Path $RepoRoot $_)) })
    if ($missing.Count) { return "registered but absent: $($missing -join ', ')" }
    return $true
}

Test-Case 'ADDITIVE the pre-existing registry entries survived the integration' {
    foreach ($n in @('Share Migration — Export', 'NDMP Copy', 'Quota Manager', 'SAS Diagnostics',
                     'Test RO User Connectivity', 'Store New Credential', 'S3 Bucket Provision (Ansible)')) {
        if ($managerSrc -notmatch [regex]::Escape("Name        = '$n'")) { return "entry lost: $n" }
    }
    return $true
}

Test-Case 'ADDITIVE the existing Get-BiggestSnapshot.ps1 is still present' {
    # This workflow adds a cross-cluster comparison; it does not replace the single-cluster script.
    Test-Path -LiteralPath (Join-Path $SnapDir 'Get-BiggestSnapshot.ps1')
}

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "  Passed: $pass" -ForegroundColor Green
if ($fail -gt 0) {
    Write-Host "  Failed: $fail" -ForegroundColor Red
    exit 1
}
Write-Host "  All offline checks passed." -ForegroundColor Green
