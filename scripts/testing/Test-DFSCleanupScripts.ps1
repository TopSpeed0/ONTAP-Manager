<#
.SYNOPSIS
    Offline tests for the DFS cleanup workflow — no cluster connection required.

.DESCRIPTION
    Validates the parts that can be wrong without anyone noticing until a deletion runs:
      - every file parses
      - the module exports what the script calls
      - FSA histogram labels parse to the right dates, including the collapsed oldest bucket
      - the verdict engine applies the 3-year / 7-year rule correctly
      - a collapsed oldest bucket cannot produce an IMMEDIATE verdict without per-file proof
      - an incomplete per-file walk is not accepted as proof
      - the config template is valid JSON with the required keys

    Run this after any change to Get-DFSCleanupAnalytics.psm1 or Invoke-DFSDecommission.ps1.

.EXAMPLE
    .\scripts\testing\Test-DFSCleanupScripts.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot   = (Resolve-Path (Join-Path $ScriptDir '..\..')).Path
$CleanupDir = Join-Path $RepoRoot 'scripts\dfs-cleanup'

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
foreach ($f in @(
        (Join-Path $CleanupDir 'Invoke-DFSDecommission.ps1'),
        (Join-Path $CleanupDir 'Get-DFSCleanupAnalytics.psm1'),
        (Join-Path $CleanupDir 'Get-NaApiCred.psm1'))) {
    Test-Case "parses: $(Split-Path -Leaf $f)" {
        if (-not (Test-Path -LiteralPath $f)) { return "missing file" }
        $errs = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$errs)
        if ($errs) { return ($errs | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) -join '; ' }
        return $true
    }
}

Write-Host "`n=== 2. Module surface ===" -ForegroundColor Cyan
Import-Module (Join-Path $CleanupDir 'Get-DFSCleanupAnalytics.psm1') -Force
Import-Module (Join-Path $CleanupDir 'Get-NaApiCred.psm1') -Force

foreach ($fn in @('Get-NaRestContext', 'Get-NaVolume', 'Get-NaVolumeList', 'Remove-NaDirectory',
                  'Get-NaDirectoryEntries', 'Find-NaDFSContainerVolumes',
                  'Enable-NaVolumeAnalytics', 'ConvertFrom-NaTimeLabel', 'Get-NaDirectoryAnalytics',
                  'Get-NaBucketSummary', 'Get-NaNewestTimestamp', 'Get-DFSCleanupVerdict',
                  'Get-DFSSubPathSuffix', 'Get-DFSDeleteClassification', 'Get-NaApiCred')) {
    Test-Case "exported: $fn" { [bool](Get-Command $fn -ErrorAction SilentlyContinue) }
}

Write-Host "`n=== 3. FSA label parsing ===" -ForegroundColor Cyan
$now = [datetime]'2026-07-29'

Test-Case "'2026 - WEEK 29' is a recent week, not collapsed" {
    $p = ConvertFrom-NaTimeLabel -Label '2026 - WEEK 29' -Now $now
    if ($p.Kind -ne 'Week') { return "Kind=$($p.Kind)" }
    if ($p.IsCollapsed) { return 'flagged collapsed' }
    if (($now - $p.NewestInstant).TotalDays -gt 30) { return "too old: $($p.NewestInstant)" }
    return $true
}
Test-Case "'2022 or OLDER' is collapsed and >3y" {
    $p = ConvertFrom-NaTimeLabel -Label '2022 or OLDER' -Now $now
    if (-not $p.IsCollapsed) { return 'not flagged collapsed' }
    if (($now - $p.NewestInstant).TotalDays / 365.25 -lt 3) { return 'age under 3y' }
    return $true
}
Test-Case "'--2Y' is collapsed" {
    (ConvertFrom-NaTimeLabel -Label '--2Y' -Now $now).IsCollapsed
}
Test-Case "'2025-Q1' parses to end of Q1" {
    $p = ConvertFrom-NaTimeLabel -Label '2025-Q1' -Now $now
    ($p.Kind -eq 'Quarter') -and ($p.NewestInstant.Month -eq 3) -and ($p.NewestInstant.Day -eq 31)
}
Test-Case "'unknown' yields no date" {
    $p = ConvertFrom-NaTimeLabel -Label 'unknown' -Now $now
    ($p.Kind -eq 'Unknown') -and ($null -eq $p.NewestInstant)
}
Test-Case "garbage label is Unparsed, not silently treated as old" {
    $p = ConvertFrom-NaTimeLabel -Label 'zzz-not-a-date' -Now $now
    ($p.Kind -eq 'Unparsed') -and ($null -eq $p.NewestInstant)
}
Test-Case "future bucket edge is clamped to now" {
    $p = ConvertFrom-NaTimeLabel -Label '2030' -Now $now
    $p.NewestInstant -le $now
}

Write-Host "`n=== 4. Verdict engine ===" -ForegroundColor Cyan

function New-FakeVolume {
    param([string]$AnalyticsState = 'on', $AccessTime = $true, $InitState = 'complete', $Supported = $true)
    [PSCustomObject]@{
        Name = 'testvol'; Uuid = 'uuid-0'; Vserver = 'svm'; State = 'online'
        AnalyticsSupported = $Supported; AnalyticsState = $AnalyticsState
        AnalyticsInitState = $InitState; AccessTimeEnabled = $AccessTime
        UsedBytes = 1GB; SizeBytes = 10GB; FilesScanned = 1; TotalFiles = 1
        JunctionPath = '/testvol'; Raw = $null
    }
}

function New-FakeAnalytics {
    param([string[]]$Labels, [int64[]]$AccessedBytes, [int64[]]$ModifiedBytes, [int64]$Bytes = 1GB,
          [int]$Files = 10, [int]$Subdirs = 1)
    $buckets = @()
    for ($i = 0; $i -lt $Labels.Count; $i++) {
        foreach ($dim in @(@{N = 'Accessed'; V = $AccessedBytes }, @{N = 'Modified'; V = $ModifiedBytes })) {
            $p = ConvertFrom-NaTimeLabel -Label $Labels[$i] -Now $now
            $buckets += [PSCustomObject]@{
                Dimension = $dim.N; Label = $p.Label; Kind = $p.Kind
                NewestInstant = $p.NewestInstant; IsCollapsed = $p.IsCollapsed
                Bytes = [int64]$dim.V[$i]
            }
        }
    }
    [PSCustomObject]@{
        Path = 'Test_Q'; HasData = $true; IncompleteData = $false
        BytesUsed = $Bytes; FileCount = $Files; SubdirCount = $Subdirs
        Buckets = $buckets; OntapNewest = @{}; OntapOldest = @{}
        RawLabels = $Labels; Raw = $null
    }
}

$labels = @('2022 or OLDER', '2024', '2025-Q4', '2026 - WEEK 29')

Test-Case 'recent activity -> ACTIVE' {
    $a = New-FakeAnalytics -Labels $labels -AccessedBytes @(0, 0, 0, 1GB) -ModifiedBytes @(0, 0, 0, 1GB)
    $v = Get-DFSCleanupVerdict -Volume (New-FakeVolume) -Analytics $a -CandidateYears 3 -ImmediateYears 7 -Now $now
    if ($v.Verdict -ne 'ACTIVE') { return "got $($v.Verdict)" }
    return $true
}

Test-Case 'all bytes in collapsed oldest bucket -> CANDIDATE (3y met, 7y unproven)' {
    $a = New-FakeAnalytics -Labels $labels -AccessedBytes @(1GB, 0, 0, 0) -ModifiedBytes @(1GB, 0, 0, 0)
    $v = Get-DFSCleanupVerdict -Volume (New-FakeVolume) -Analytics $a -CandidateYears 3 -ImmediateYears 7 `
            -RequirePerFileProof -Now $now
    if ($v.Verdict -ne 'CANDIDATE') { return "got $($v.Verdict)" }
    if (-not $v.IsLowerBound) { return 'age should be flagged as a lower bound' }
    return $true
}

Test-Case 'collapsed bucket + complete per-file proof of 9y -> IMMEDIATE' {
    $a = New-FakeAnalytics -Labels $labels -AccessedBytes @(1GB, 0, 0, 0) -ModifiedBytes @(1GB, 0, 0, 0)
    $proof = [PSCustomObject]@{
        Path = 'Test_Q'; NewestAccessed = $now.AddYears(-9); NewestModified = $now.AddYears(-11)
        NewestFile = 'old.txt'; FilesSeen = 42; DirsVisited = 4; Complete = $true; Notes = @()
    }
    $v = Get-DFSCleanupVerdict -Volume (New-FakeVolume) -Analytics $a -PerFile $proof `
            -CandidateYears 3 -ImmediateYears 7 -RequirePerFileProof -Now $now
    if ($v.Verdict -ne 'IMMEDIATE') { return "got $($v.Verdict): $($v.Reasons -join ' ')" }
    return $true
}

Test-Case 'INCOMPLETE per-file walk is refused as proof -> CANDIDATE' {
    $a = New-FakeAnalytics -Labels $labels -AccessedBytes @(1GB, 0, 0, 0) -ModifiedBytes @(1GB, 0, 0, 0)
    $proof = [PSCustomObject]@{
        Path = 'Test_Q'; NewestAccessed = $now.AddYears(-9); NewestModified = $now.AddYears(-11)
        NewestFile = 'old.txt'; FilesSeen = 10; DirsVisited = 2000; Complete = $false
        Notes = @('Directory budget exhausted.')
    }
    $v = Get-DFSCleanupVerdict -Volume (New-FakeVolume) -Analytics $a -PerFile $proof `
            -CandidateYears 3 -ImmediateYears 7 -RequirePerFileProof -Now $now
    if ($v.Verdict -ne 'CANDIDATE') { return "got $($v.Verdict)" }
    return $true
}

Test-Case 'per-file proof NEWER than histogram lowers the verdict' {
    $a = New-FakeAnalytics -Labels $labels -AccessedBytes @(1GB, 0, 0, 0) -ModifiedBytes @(1GB, 0, 0, 0)
    $proof = [PSCustomObject]@{
        Path = 'Test_Q'; NewestAccessed = $now.AddMonths(-2); NewestModified = $now.AddYears(-8)
        NewestFile = 'recent.txt'; FilesSeen = 5; DirsVisited = 1; Complete = $true; Notes = @()
    }
    $v = Get-DFSCleanupVerdict -Volume (New-FakeVolume) -Analytics $a -PerFile $proof `
            -CandidateYears 3 -ImmediateYears 7 -RequirePerFileProof -Now $now
    if ($v.Verdict -ne 'ACTIVE') { return "got $($v.Verdict)" }
    return $true
}

Test-Case 'read-cold but write-warm is NOT idle' {
    # Nothing accessed for years, but written last week — must not be a candidate.
    $a = New-FakeAnalytics -Labels $labels -AccessedBytes @(1GB, 0, 0, 0) -ModifiedBytes @(0, 0, 0, 1GB)
    $v = Get-DFSCleanupVerdict -Volume (New-FakeVolume) -Analytics $a -CandidateYears 3 -ImmediateYears 7 -Now $now
    if ($v.Verdict -ne 'ACTIVE') { return "got $($v.Verdict)" }
    return $true
}

Test-Case 'FSA off -> NO_ANALYTICS' {
    $a = New-FakeAnalytics -Labels $labels -AccessedBytes @(1GB, 0, 0, 0) -ModifiedBytes @(1GB, 0, 0, 0)
    $v = Get-DFSCleanupVerdict -Volume (New-FakeVolume -AnalyticsState 'off') -Analytics $a -Now $now
    if ($v.Verdict -ne 'NO_ANALYTICS') { return "got $($v.Verdict)" }
    return $true
}

Test-Case 'FSA still initializing -> NO_ANALYTICS' {
    $a = New-FakeAnalytics -Labels $labels -AccessedBytes @(1GB, 0, 0, 0) -ModifiedBytes @(1GB, 0, 0, 0)
    $v = Get-DFSCleanupVerdict -Volume (New-FakeVolume -InitState 'running') -Analytics $a -Now $now
    if ($v.Verdict -ne 'NO_ANALYTICS') { return "got $($v.Verdict)" }
    return $true
}

Test-Case 'access_time disabled -> immediate deletion withheld' {
    $a = New-FakeAnalytics -Labels $labels -AccessedBytes @(1GB, 0, 0, 0) -ModifiedBytes @(1GB, 0, 0, 0)
    $v = Get-DFSCleanupVerdict -Volume (New-FakeVolume -AccessTime $false) -Analytics $a `
            -CandidateYears 3 -ImmediateYears 7 -Now $now
    if ($v.Verdict -eq 'IMMEDIATE') { return 'IMMEDIATE granted without trustworthy atime' }
    return $true
}

Test-Case 'no files and no subdirectories -> EMPTY' {
    $a = New-FakeAnalytics -Labels $labels -AccessedBytes @(0, 0, 0, 0) -ModifiedBytes @(0, 0, 0, 0) `
            -Bytes 0 -Files 0 -Subdirs 0
    $v = Get-DFSCleanupVerdict -Volume (New-FakeVolume) -Analytics $a -Now $now
    if ($v.Verdict -ne 'EMPTY') { return "got $($v.Verdict)" }
    return $true
}

Test-Case 'REGRESSION an empty qtree whose only bytes are the directory inode -> EMPTY' {
    # The real shape, measured in production: an empty qtree reported BytesUsed 4096 / FileCount 0 /
    # SubdirCount 0 and was verified by direct listing to hold zero entries. The old rule tested
    # BytesUsed -eq 0, never fired, and the row fell through to the histogram — where the only
    # bucket is that same inode with an access time of THIS WEEK, because listing the directory
    # updated its atime. A provably empty qtree therefore came back ACTIVE, which blocks deletion.
    $a = New-FakeAnalytics -Labels $labels -AccessedBytes @(4096, 0, 0, 0) -ModifiedBytes @(4096, 0, 0, 0) `
            -Bytes 4096 -Files 0 -Subdirs 0
    $v = Get-DFSCleanupVerdict -Volume (New-FakeVolume) -Analytics $a -Now $now
    if ($v.Verdict -ne 'EMPTY') { return "got $($v.Verdict) — inode bytes are being counted as content" }
    return $true
}

Test-Case 'SAFETY subdirectories but no files is NOT empty' {
    $a = New-FakeAnalytics -Labels $labels -AccessedBytes @(0, 0, 0, 8192) -ModifiedBytes @(0, 0, 0, 8192) `
            -Bytes 8192 -Files 0 -Subdirs 3
    $v = Get-DFSCleanupVerdict -Volume (New-FakeVolume) -Analytics $a -Now $now
    if ($v.Verdict -eq 'EMPTY') { return 'a directory holding 3 subdirectories was called EMPTY' }
    return $true
}

Test-Case 'SAFETY a path that does not exist (404) -> GONE, not NO_ANALYTICS' {
    # Opposite instructions: NO_ANALYTICS says wait for the scan, GONE says the row is finished.
    # Verified in production: a parent qtree listed 22 subdirectories, none matching the three
    # tracker rows below it; and one share's path named a qtree absent from the qtree table.
    $missing = [PSCustomObject]@{
        Path = 'Parent_Q/MissingChild'; PathMissing = $true; HasData = $false
        BytesUsed = $null; FileCount = $null; SubdirCount = $null
        IncompleteData = $null; Buckets = @(); RawLabels = @()
    }
    $v = Get-DFSCleanupVerdict -Volume (New-FakeVolume) -Analytics $missing -Now $now
    if ($v.Verdict -ne 'GONE') { return "got $($v.Verdict)" }
    # And it must win even while the volume is still scanning — absence is settled either way.
    $init = [PSCustomObject]@{ Name = 'V'; AnalyticsState = 'initializing'; AnalyticsInitState = 'running'
                               AccessTimeEnabled = $true; AnalyticsSupported = $true }
    $v2 = Get-DFSCleanupVerdict -Volume $init -Analytics $missing -Now $now
    if ($v2.Verdict -ne 'GONE') { return "while initializing, got $($v2.Verdict)" }
    return $true
}

Test-Case 'SAFETY missing bytes/file counts -> NO_ANALYTICS, never EMPTY' {
    # A failed analytics read must not read as "nothing here". EMPTY is deletable by default,
    # so treating null as zero turns a broken read into "safe to delete everything".
    foreach ($mut in @(
            @{ HasData = $false; BytesUsed = $null; FileCount = $null },
            @{ HasData = $true;  BytesUsed = $null; FileCount = 0 },
            @{ HasData = $true;  BytesUsed = 0;     FileCount = $null })) {
        $a = New-FakeAnalytics -Labels $labels -AccessedBytes @(0, 0, 0, 0) -ModifiedBytes @(0, 0, 0, 0) -Bytes 0 -Files 0
        foreach ($k in $mut.Keys) { $a.$k = $mut[$k] }
        $v = Get-DFSCleanupVerdict -Volume (New-FakeVolume) -Analytics $a -Now $now
        if ($v.Verdict -eq 'EMPTY') { return "EMPTY returned for $($mut | ConvertTo-Json -Compress)" }
        if ($v.Verdict -ne 'NO_ANALYTICS') { return "got $($v.Verdict) for $($mut | ConvertTo-Json -Compress)" }
    }
    return $true
}

Test-Case 'SAFETY incomplete_data -> NO_ANALYTICS' {
    $a = New-FakeAnalytics -Labels $labels -AccessedBytes @(1GB, 0, 0, 0) -ModifiedBytes @(1GB, 0, 0, 0)
    $a.IncompleteData = $true
    $v = Get-DFSCleanupVerdict -Volume (New-FakeVolume) -Analytics $a -CandidateYears 3 -ImmediateYears 7 -Now $now
    if ($v.Verdict -ne 'NO_ANALYTICS') { return "got $($v.Verdict)" }
    return $true
}

Test-Case "ONTAP's real bucket label '--2022' parses as collapsed, not Unparsed" {
    $p = ConvertFrom-NaTimeLabel -Label '--2022' -Now $now
    if ($p.Kind -ne 'Collapsed') { return "Kind=$($p.Kind)" }
    if (-not $p.IsCollapsed) { return 'not flagged collapsed' }
    if ($p.NewestInstant.Year -ne 2022) { return "year=$($p.NewestInstant.Year)" }
    return $true
}

Test-Case "ONTAP's real label set all parses (no Unparsed)" {
    # Exact label set a production ONTAP 9.x cluster returned for one qtree.
    $real = @('2026-W31','2026-W30','2026-W29','2026-W28','2026-W27','2026-07','2026-06','2026-05',
              '2026-Q3','2026-Q2','2026-Q1','2025-Q4','2026','2025','2024','2023','--2022','unknown')
    $bad = @()
    foreach ($l in $real) {
        $p = ConvertFrom-NaTimeLabel -Label $l -Now $now
        if ($p.Kind -eq 'Unparsed') { $bad += $l }
    }
    if ($bad) { return "unparsed: $($bad -join ', ')" }
    return $true
}

Write-Host "`n=== 5. Config template ===" -ForegroundColor Cyan
Test-Case 'Config_DFSCleanup.template.json is valid JSON with required keys' {
    $tpl = Join-Path $RepoRoot 'Config_DFSCleanup.template.json'
    if (-not (Test-Path -LiteralPath $tpl)) { return 'template missing' }
    $c = (Get-Content -LiteralPath $tpl -Raw | ConvertFrom-Json).DFSCleanup
    if (-not $c) { return 'no DFSCleanup section' }
    foreach ($k in @('ClusterAlias', 'RestHost', 'CyberArk', 'AgeThresholds', 'ProtectedVolumes', 'Excel')) {
        if ($c.PSObject.Properties.Name -notcontains $k) { return "missing key: $k" }
    }
    if ($c.AgeThresholds.CandidateYears -ge $c.AgeThresholds.ImmediateYears) {
        return 'CandidateYears must be less than ImmediateYears'
    }
    if ($c.Excel.WriteMode -ne 'Copy') { return "template default WriteMode should be Copy, is '$($c.Excel.WriteMode)'" }
    return $true
}

Test-Case 'Delete mode refuses to run without -VerdictFile' {
    $script = Join-Path $CleanupDir 'Invoke-DFSDecommission.ps1'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$null, [ref]$null)
    $text = $ast.Extent.Text
    # The guard must exist and must not be reachable-around via -Force.
    ($text -match "Mode Delete requires -VerdictFile") -and ($text -match '\$Mode\s+-eq\s+.Delete.')
}

Write-Host "`n=== 6. Approval gate ===" -ForegroundColor Cyan

# Pull the guard functions out of the script by AST so they can be exercised without running
# the script body (which connects to a cluster).
$mainScript = Join-Path $CleanupDir 'Invoke-DFSDecommission.ps1'
$mainAst = [System.Management.Automation.Language.Parser]::ParseFile($mainScript, [ref]$null, [ref]$null)
foreach ($name in @('Test-DeletionAllowed', 'Get-DFSNameCandidate')) {
    $fnAst = $mainAst.FindAll({
            param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name
        }, $true) | Select-Object -First 1
    if ($fnAst) { . ([scriptblock]::Create($fnAst.Extent.Text)) }
}

$fakeCfg = [PSCustomObject]@{ Protected = @('datavol1') }
function New-VerdictMap {
    param([string]$Verdict, [string]$ApprovedValue, [bool]$IncludeApprovedColumn = $true)
    $row = [ordered]@{ DfsPath = '\\ns\dfs\thing'; Verdict = $Verdict; YearsIdle = 9 }
    if ($IncludeApprovedColumn) { $row['Approved'] = $ApprovedValue }
    @{ '\\ns\dfs\thing' = [PSCustomObject]$row }
}
$fakeRow = [PSCustomObject]@{ DfsPath = '\\ns\dfs\thing' }

Test-Case 'IMMEDIATE but Approved blank -> REFUSED' {
    $r = Test-DeletionAllowed -Cfg $fakeCfg -Row $fakeRow -Approved @('IMMEDIATE', 'EMPTY') `
            -VerdictMap (New-VerdictMap -Verdict 'IMMEDIATE' -ApprovedValue '')
    if ($r.Allowed) { return 'allowed without approval' }
    return $true
}

Test-Case 'IMMEDIATE with no Approved column at all -> REFUSED' {
    $r = Test-DeletionAllowed -Cfg $fakeCfg -Row $fakeRow -Approved @('IMMEDIATE', 'EMPTY') `
            -VerdictMap (New-VerdictMap -Verdict 'IMMEDIATE' -ApprovedValue '' -IncludeApprovedColumn $false)
    if ($r.Allowed) { return 'allowed with no approval column' }
    return $true
}

Test-Case 'IMMEDIATE + Approved=YES -> allowed' {
    $r = Test-DeletionAllowed -Cfg $fakeCfg -Row $fakeRow -Approved @('IMMEDIATE', 'EMPTY') `
            -VerdictMap (New-VerdictMap -Verdict 'IMMEDIATE' -ApprovedValue 'YES')
    if (-not $r.Allowed) { return "refused: $($r.Reason)" }
    return $true
}

Test-Case 'CANDIDATE + Approved=YES still refused (verdict not in approved set)' {
    $r = Test-DeletionAllowed -Cfg $fakeCfg -Row $fakeRow -Approved @('IMMEDIATE', 'EMPTY') `
            -VerdictMap (New-VerdictMap -Verdict 'CANDIDATE' -ApprovedValue 'YES')
    if ($r.Allowed) { return 'CANDIDATE allowed by default' }
    return $true
}

Test-Case 'unknown path -> REFUSED' {
    $r = Test-DeletionAllowed -Cfg $fakeCfg -Row ([PSCustomObject]@{ DfsPath = '\\ns\dfs\other' }) `
            -Approved @('IMMEDIATE') -VerdictMap (New-VerdictMap -Verdict 'IMMEDIATE' -ApprovedValue 'YES')
    if ($r.Allowed) { return 'allowed with no stored verdict' }
    return $true
}

Write-Host "`n=== 7. Subfolder-share safety ===" -ForegroundColor Cyan

Test-Case 'Remove-NaDirectory refuses an empty path (would target volume root)' {
    $ctx = Get-NaRestContext -RestHost 'example.invalid' -Username 'u' `
                -Password (ConvertTo-SecureString 'x' -AsPlainText -Force)
    # '' is rejected at parameter binding by [Parameter(Mandatory)][string]; '/' and '   ' reach
    # the explicit guard. Either refusal is acceptable — what matters is that none get through.
    foreach ($p in @('', '/', '   ')) {
        try {
            Remove-NaDirectory -Context $ctx -VolumeUuid 'uuid' -Path $p -WhatIf | Out-Null
            return "accepted volume-root path '$p'"
        }
        catch {
            $m = $_.Exception.Message
            if ($m -notmatch 'refuses an empty path' -and $m -notmatch 'empty string') {
                return "unexpected error for '$p': $m"
            }
        }
    }
    return $true
}

Test-Case 'script delegates classification to the tested pure functions' {
    $text = $mainAst.Extent.Text
    if ($text -notmatch 'Get-DFSSubPathSuffix') { return 'script does not call Get-DFSSubPathSuffix' }
    if ($text -notmatch 'Get-DFSDeleteClassification') { return 'script does not call Get-DFSDeleteClassification' }
    if ($text -notmatch 'Refusing rather than risk deleting siblings') { return 'no qtree/sub-path guard in the delete path' }
    return $true
}

Test-Case 'SAFETY analytics measure DeleteRelPath, not the parent qtree' {
    # Measuring $Row.Qtree gave every subfolder target its PARENT's figures: three sibling
    # subfolder rows each reported the whole qtree's 1.55 TiB / 1.2M files and all came back
    # ACTIVE. The dangerous direction is the reverse — a cold qtree would hand its IMMEDIATE
    # verdict to a hot subfolder inside it, marking live data for deletion.
    $text = $mainAst.Extent.Text
    if ($text -notmatch '\$fsaPath\s*=\s*if\s*\(\$Row\.DeleteRelPath\)') {
        return 'FSA path is not taken from DeleteRelPath first'
    }
    if ($text -match '\$fsaPath\s*=\s*if\s*\(\$Row\.Qtree\)\s*\{\s*\$Row\.Qtree\s*\}\s*else') {
        return 'FSA path still measures the parent qtree'
    }
    return $true
}

# --- The Dept_Q case: real production data that would have destroyed a shared qtree ---------

Test-Case 'REGRESSION \\ns\dfs\Dept\SubOne is a sub-path, not the Dept_Q qtree' {
    $s = Get-DFSSubPathSuffix -DfsPath '\\ns\dfs\Dept\SubOne' -Link '/vol/dfsroot/Dept'
    if ($s -ne 'SubOne') { return "suffix='$s', expected 'SubOne'" }
    $c = Get-DFSDeleteClassification -SharePath '/datavol2/Dept_Q' -UnixPath '/Dept/' `
            -SubPathSuffix $s -QtreeExists $true -IsWidelink $true
    if ($c.DeleteMethod -ne 'Directory') { return "method=$($c.DeleteMethod), expected Directory" }
    if ($c.DeleteRelPath -ne 'Dept_Q/SubOne') { return "relpath=$($c.DeleteRelPath)" }
    return $true
}

Test-Case 'REGRESSION sibling subfolders of one qtree get distinct delete paths' {
    $paths = @('\\ns\dfs\Dept\SubOne', '\\ns\dfs\Dept\SubTwo', '\\ns\dfs\Dept\PT')
    $rels = foreach ($p in $paths) {
        $s = Get-DFSSubPathSuffix -DfsPath $p -Link '/vol/dfsroot/Dept'
        (Get-DFSDeleteClassification -SharePath '/datavol2/Dept_Q' -UnixPath '/Dept/' `
            -SubPathSuffix $s -QtreeExists $true -IsWidelink $true).DeleteRelPath
    }
    if (@($rels | Select-Object -Unique).Count -ne 3) { return "collapsed to: $($rels -join ', ')" }
    if ($rels -contains 'Dept_Q') { return 'one target collapsed to the bare qtree' }
    return $true
}

Test-Case 'a genuine nested DFS link yields no sub-path (qtree primitive is correct)' {
    # Resolver consumed the component: LINK ends with it.
    $s = Get-DFSSubPathSuffix -DfsPath '\\ns\dfs\tn\TrainShare' -Link '/vol/dfsroot/tn/TrainShare'
    if ($s -ne '') { return "suffix='$s', expected empty" }
    $c = Get-DFSDeleteClassification -SharePath '/Datavol3/TrainShare_Q' -UnixPath '/TrainShare/' `
            -SubPathSuffix $s -QtreeExists $true -IsWidelink $true
    if ($c.DeleteMethod -ne 'Qtree') { return "method=$($c.DeleteMethod), expected Qtree" }
    return $true
}

Test-Case 'plain widelink to a qtree stays a qtree delete' {
    $s = Get-DFSSubPathSuffix -DfsPath '\\ns\dfs\Sample' -Link '/vol/dfsroot/Sample'
    $c = Get-DFSDeleteClassification -SharePath '/Datavol3/Sample_Q' -UnixPath '/Sample/' `
            -SubPathSuffix $s -QtreeExists $true -IsWidelink $true
    ($s -eq '') -and ($c.DeleteMethod -eq 'Qtree') -and ($c.DeleteRelPath -eq 'Sample_Q') -and
        ($c.TargetType -eq 'QtreeWidelink')
}

Test-Case 'REGRESSION hidden share with no SharePath is NOT a whole-volume delete' {
    # \\ns\TempShare$ — resolver puts the share path in UnixPath and leaves SharePath empty.
    $c = Get-DFSDeleteClassification -SharePath '' -UnixPath '/datavol4/Tmp_Q' `
            -SubPathSuffix '' -QtreeExists $true -IsWidelink $false
    if ($c.DeleteMethod -eq 'Volume') { return 'classified as a whole-volume delete' }
    if ($c.DeleteMethod -ne 'Qtree') { return "method=$($c.DeleteMethod), expected Qtree" }
    if ($c.DeleteRelPath -ne 'Tmp_Q') { return "relpath=$($c.DeleteRelPath)" }
    return $true
}

Test-Case 'widelink UnixPath (single component) is not mistaken for a share path' {
    $c = Get-DFSDeleteClassification -SharePath '' -UnixPath '/Sample/' `
            -SubPathSuffix '' -QtreeExists $true -IsWidelink $true
    # Nothing usable to measure depth with -> volume root, not a bogus qtree.
    ($c.DeleteMethod -eq 'Volume') -and ($c.DeleteRelPath -eq '')
}

Test-Case 'an unverified qtree becomes a Directory delete, never a Qtree delete' {
    $c = Get-DFSDeleteClassification -SharePath '/datavol1/SomeFolder' -UnixPath '' `
            -SubPathSuffix '' -QtreeExists $false -IsWidelink $true
    ($c.DeleteMethod -eq 'Directory') -and ($c.DeleteRelPath -eq 'SomeFolder')
}

Test-Case 'share path deeper than a qtree is always a Directory delete' {
    $c = Get-DFSDeleteClassification -SharePath '/datavol1/App_Q/SomeFolder/Deeper' -UnixPath '' `
            -SubPathSuffix '' -QtreeExists $true -IsWidelink $true
    ($c.DeleteMethod -eq 'Directory') -and ($c.DeleteRelPath -eq 'App_Q/SomeFolder/Deeper')
}

Test-Case 'deep UNC beyond the resolver limit keeps every component' {
    $s = Get-DFSSubPathSuffix -DfsPath '\\ns\dfs\link\qtree\sub\deeper' -Link '/vol/dfsroot/link'
    if ($s -ne 'qtree/sub/deeper') { return "suffix='$s'" }
    return $true
}

Test-Case 'directory delete refuses when DeleteRelPath is empty' {
    ($mainAst.Extent.Text -match 'DeleteRelPath is empty')
}

Write-Host "`n=== 8. Orphan fallback ===" -ForegroundColor Cyan

Test-Case 'name candidate derived from assorted UNC shapes' {
    $cases = @{
        '\\ns\dfs\Alpha'                = 'Alpha'
        '\\cifsAlias\Birthday$'       = 'Birthday'
        '\\ns\dfs\Dept\PT'              = 'PT'
        '\\ns\dfs\lookalike'             = 'lookalike'
        '\\l\Neumunster_Engineering$' = 'Neumunster_Engineering'
        '\\ns\dfs\Arch'                = 'Arch'
    }
    foreach ($k in $cases.Keys) {
        $got = Get-DFSNameCandidate -DfsPath $k
        if ($got -ne $cases[$k]) { return "'$k' -> '$got', expected '$($cases[$k])'" }
    }
    return $true
}

Test-Case 'REGRESSION lookalike shape: _Q name that is NOT a qtree -> Directory' {
    # Real case: share 'lookalike' -> /Datavol3/lookalike_Q, where lookalike_Q is a plain directory.
    # 1.5 TiB. Naming looks exactly like a qtree; only the existence check tells them apart.
    $c = Get-DFSDeleteClassification -SharePath '/Datavol3/lookalike_Q' -UnixPath '' `
            -SubPathSuffix '' -QtreeExists $false -IsWidelink $false
    if ($c.DeleteMethod -ne 'Directory') { return "method=$($c.DeleteMethod), expected Directory" }
    if ($c.DeleteRelPath -ne 'lookalike_Q') { return "relpath=$($c.DeleteRelPath)" }
    return $true
}

Test-Case 'REGRESSION Arch shape: _Q name that IS a qtree -> Qtree' {
    $c = Get-DFSDeleteClassification -SharePath '/Datavol3/Arch_Q' -UnixPath '' `
            -SubPathSuffix '' -QtreeExists $true -IsWidelink $false
    ($c.DeleteMethod -eq 'Qtree') -and ($c.DeleteRelPath -eq 'Arch_Q')
}

Test-Case 'orphan fallback is attempted before declaring a target deleted' {
    $text = $mainAst.Extent.Text
    if ($text -notmatch 'Resolve-DFSTargetByName') { return 'fallback function never called' }
    if ($text -notmatch "OrphanState\s*=\s*'FullyGone'") { return 'no FullyGone state' }
    if ($text -notmatch "OrphanState\s*=\s*'Live'") { return 'no Live state' }
    # The resolver's own values must not overwrite fallback findings.
    if ($text -notmatch 'if \(\$info\) \{') { return 'resolver population is not guarded by $info' }
    return $true
}

Write-Host "`n=== 9. Tracker written in place ===" -ForegroundColor Cyan

Test-Case 'the per-run DFS_Cleanup_<stamp> sheet is gone' {
    $text = $mainAst.Extent.Text
    if ($text -match 'Export-Excel[^\r\n]*DFS_Cleanup_\$RunStamp') {
        return 'still exporting a dated results sheet — a path added in column A would stay blank'
    }
    if ($text -match "WorksheetName\s+`"DFS_Cleanup_") { return 'dated worksheet name still referenced' }
    return $true
}

Test-Case 'Report updates the tracker worksheet in place' {
    $text = $mainAst.Extent.Text
    if ($text -notmatch 'function Update-DFSWorkbookInPlace') { return 'writer function missing' }
    if ($text -notmatch 'Update-DFSWorkbookInPlace\s+-Path') { return 'writer is never called' }
    # Open-ExcelPackage, not Export-Excel: Export-Excel replaces the sheet and would destroy the
    # title block, the styling and the Actual Path formula on every row.
    if ($text -notmatch 'Open-ExcelPackage') { return 'not using Open-ExcelPackage — styling/formulas would be lost' }
    return $true
}

Test-Case 'SAFETY hand-written columns are never overwritten' {
    $text = $mainAst.Extent.Text
    if ($text -notmatch '\$humanColumns\s*=\s*@\(') { return 'no human-column guard list' }
    foreach ($c in @('Comments', 'commands', 'Is Backuped', 'Actual Path')) {
        if ($text -notmatch "\`$humanColumns[^\r\n]*'$c'") {
            # allow the list to span lines
            $block = [regex]::Match($text, '\$humanColumns\s*=\s*@\([^\)]*\)').Value
            if ($block -notmatch "'$($c -replace '\\','')'") { return "'$c' is not protected" }
        }
    }
    return $true
}

Test-Case 'Size (GB) and Status are re-measured every run, not hand-maintained' {
    $text = $mainAst.Extent.Text
    if ($text -notmatch "'Size \(GB\)'\s*=\s*'SizeMeasured'") { return 'Size (GB) is not mapped to a measured value' }
    if ($text -notmatch "'Status'\s*=\s*'Status'") { return 'Status is not mapped' }
    # And it must NOT be in the never-write list, or the mapping would be dead code.
    $block = [regex]::Match($text, '\$humanColumns\s*=\s*@\([^\)]*\)').Value
    if ($block -match 'Size \(GB\)') { return 'Size (GB) is still protected — the mapping can never fire' }
    if ($block -notmatch 'Comments') { return 'Comments protection was lost' }
    if ($block -notmatch 'Is Backuped') { return 'Is Backuped protection was lost' }
    return $true
}

Test-Case 'a measured size distinguishes empty from real content' {
    $text = $mainAst.Extent.Text
    $fn = [regex]::Match($text, 'function Add-DFSTrackerFields(.|\n)*?\n\}\n').Value
    if (-not $fn) { return 'producer not found' }
    if ($fn -notmatch "'0 \(empty\)'") { return 'inode-only bytes are reported as content' }
    if ($fn -notmatch 'TiB' -or $fn -notmatch 'GiB') { return 'no human-readable scaling' }
    return $true
}

Test-Case 'SAFETY a gone target does not erase what was measured before it went' {
    # After a deletion the size and timestamps ARE the record of what was removed. Writing
    # 'n/a - gone' over them would destroy the only evidence of what the row used to hold.
    # $null is what leaves a cell alone, so these four must resolve to $null when gone.
    $text = $mainAst.Extent.Text
    $fn = [regex]::Match($text, 'function Add-DFSTrackerFields(.|\n)*?\n\}\n').Value
    if (-not $fn) { return 'producer not found' }
    # Match an ASSIGNMENT, not a mention — the comments explaining this decision quote the old
    # strings on purpose, and a bare substring check flagged those instead of real code.
    if ($fn -match '=\s*''n/a - gone''') { return "still assigns 'n/a - gone' over history" }
    if ($fn -match '=\s*''n/a - target no longer exists''') { return 'still overwrites Content (measured)' }
    if ($fn -notmatch '\$isGone\s*=\s*\(\$Row\.Verdict -eq ''GONE''') { return 'no gone test' }
    if ($fn -notmatch 'if \(\$isGone\) \{ \$lastAcc = \$null; \$lastMod = \$null \}') {
        return 'timestamps are not preserved on a gone target'
    }
    if ($fn -notmatch 'LAST MEASURED values') { return 'the reader is not told the figures are frozen' }
    return $true
}

Test-Case 'Status reflects the GONE verdict, not just the orphan state' {
    $text = $mainAst.Extent.Text
    $fn = [regex]::Match($text, 'function Add-DFSTrackerFields(.|\n)*?\n\}\n').Value
    if ($fn -notmatch "\`$Row\.Verdict -eq 'GONE'") { return 'a 404-derived GONE verdict does not reach Status' }
    if ($fn -notmatch "\`$Row\.Verdict -eq 'EMPTY'") { return 'an EMPTY verdict does not reach Status' }
    return $true
}

Test-Case 'Last Accessed and Last Modified reach the tracker' {
    $text = $mainAst.Extent.Text
    if ($text -notmatch "'Last Accessed'\s*=\s*'LastAccessedText'") { return 'Last Accessed is not mapped' }
    if ($text -notmatch "'Last Modified'\s*=\s*'LastModifiedText'") { return 'Last Modified is not mapped' }
    $fn = [regex]::Match($text, 'function Add-DFSTrackerFields(.|\n)*?\n\}\n').Value
    if ($fn -notmatch 'NewestAccessed') { return 'per-file timestamps are not used when available' }
    if ($fn -notmatch 'FSA period') { return 'a histogram bucket is presented as if it were a date' }
    if ($fn -notmatch 'may include this scan') { return 'contaminated access time is not flagged to the reader' }
    return $true
}

Test-Case 'a mapped column missing from the sheet is created, not skipped' {
    $text = $mainAst.Extent.Text
    $fn = [regex]::Match($text, 'function Update-DFSWorkbookInPlace(.|\n)*?\n\}\n').Value
    if ($fn -notmatch 'Added missing column') { return 'missing columns are silently dropped' }
    # Appended at the end, so existing column positions are not disturbed.
    if ($fn -notmatch '\$lastCol\+\+') { return 'new headers are not appended at the end' }
    if ($fn -notmatch '\$hdr -in \$humanColumns') { return 'a human column could be auto-created and then written' }
    return $true
}

Test-Case 'SAFETY a null result never blanks an existing cell' {
    $text = $mainAst.Extent.Text
    $fn = [regex]::Match($text, 'function Update-DFSWorkbookInPlace(.|\n)*?\n\}\n').Value
    if (-not $fn) { return 'could not isolate the writer' }
    if ($fn -notmatch "if \(\`$null -eq \`$value -or \(\`$value -is \[string\] -and \`$value -eq ''\)\) \{ continue \}") {
        return 'null/empty values are not skipped — a failed cluster read would erase good data'
    }
    return $true
}

Test-Case 'SAFETY formula cells are left alone' {
    $text = $mainAst.Extent.Text
    if ($text -notmatch 'if \(\$cell\.Formula\)\s*\{\s*\$skippedFormula\+\+;\s*continue\s*\}') {
        return 'formula cells are not skipped'
    }
    return $true
}

Test-Case 'paths analysed but absent from the sheet are reported, not dropped' {
    $text = $mainAst.Extent.Text
    if ($text -notmatch '\$unmatched') { return 'no unmatched tracking' }
    if ($text -notmatch 'had no row in') { return 'unmatched paths are not surfaced to the operator' }
    return $true
}

Test-Case 'tracker columns with no producer are computed' {
    $text = $mainAst.Extent.Text
    if ($text -notmatch 'function Add-DFSTrackerFields') { return 'producer function missing' }
    if ($text -notmatch 'Add-DFSTrackerFields\s+-Context') { return 'producer is never called' }
    foreach ($f in @('ContentMeasured', 'DfsEnabled', 'ClusterCheck', 'Status', 'AutoNotes', 'FsaStateText')) {
        if ($text -notmatch "'$f'") { return "$f is not produced" }
    }
    return $true
}

Test-Case 'the emptiness probe does not enumerate a million-file directory' {
    $text = (Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\dfs-cleanup\Get-DFSCleanupAnalytics.psm1') -Raw)
    if ($text -notmatch '\[switch\]\$FirstPageOnly') { return 'no FirstPageOnly switch on Get-NaDirectoryEntries' }
    if ($text -notmatch '-FollowPaging:\(-not \$FirstPageOnly\)') { return 'FirstPageOnly is not honoured' }
    $main = $mainAst.Extent.Text
    # The call is wrapped across lines with a backtick, so this must not be line-anchored.
    if ($main -notmatch '(?s)Get-NaDirectoryEntries.{0,200}?-FirstPageOnly') {
        return 'the content probe still follows paging to the end'
    }
    return $true
}

Test-Case 'the tracker is backed up before it is modified' {
    $text = $mainAst.Extent.Text
    if ($text -notmatch '\.bak-\$RunStamp\.xlsx') { return 'no pre-write backup' }
    if ($text -notmatch 'Copy-Item -LiteralPath \$xlsxSource -Destination \$backup') { return 'backup is never taken' }
    return $true
}

Write-Host "`n=== 10. Operator confirmation gate ===" -ForegroundColor Cyan

Test-Case 'deletion runs the three-challenge gate before removing anything' {
    $text = $mainAst.Extent.Text
    if ($text -notmatch 'function Confirm-DFSDeletion') { return 'gate function missing' }
    if ($text -notmatch 'Confirm-DFSDeletion -Row \$row') { return 'gate is never called' }
    # The gate must be reached before the removal call inside the Delete branch. Anchoring on the
    # branch's closing brace was too brittle to be a useful guard, so this checks ordering from
    # the branch opener to the end of the script instead.
    $i = $text.IndexOf("if (`$Mode -eq 'Delete')")
    if ($i -lt 0) { return 'Delete branch not found' }
    $del = $text.Substring($i)
    $g = $del.IndexOf('Confirm-DFSDeletion')
    $r = $del.IndexOf('Remove-DFSTarget -Cfg')
    if ($g -lt 0) { return 'gate is not in the Delete branch' }
    if ($r -lt 0) { return 'removal call not found in the Delete branch' }
    if ($g -gt $r) { return 'gate runs after the removal call' }
    return $true
}

Test-Case 'SAFETY -Force cannot bypass the confirmation gate' {
    $text = $mainAst.Extent.Text
    $fn = [regex]::Match($text, 'function Confirm-DFSDeletion(.|\n)*?\n\}\n').Value
    if (-not $fn) { return 'could not isolate the gate' }
    if ($fn -match '\$Force' -or $fn -match '\$NoPrompt') { return 'gate consults -Force / -NoPrompt' }
    # And the call site must not gate it behind -Force either.
    if ($text -match 'if \(-not \$Force[^\r\n]*Confirm-DFSDeletion') { return 'call site skips the gate under -Force' }
    return $true
}

Test-Case 'SAFETY a non-interactive session refuses to delete' {
    $text = $mainAst.Extent.Text
    if ($text -notmatch 'function Test-DFSInteractiveConsole') { return 'no interactivity check' }
    if ($text -notmatch 'IsInputRedirected') { return 'redirected stdin is not detected — Read-Host would return empty' }
    if ($text -notmatch 'UserInteractive') { return 'service/scheduled-task context is not detected' }
    $fn = [regex]::Match($text, 'function Confirm-DFSDeletion(.|\n)*?\n\}\n').Value
    if ($fn -notmatch 'if \(-not \(Test-DFSInteractiveConsole\)\)') { return 'gate does not check interactivity' }
    if ($fn -notmatch '(?s)Test-DFSInteractiveConsole.{0,220}return \$false') { return 'non-interactive path does not refuse' }
    return $true
}

Test-Case 'the arithmetic challenge is randomised per call' {
    $text = $mainAst.Extent.Text
    $fn = [regex]::Match($text, 'function Confirm-DFSDeletion(.|\n)*?\n\}\n').Value
    if ($fn -notmatch '\$a = Get-Random') { return 'first operand is not random' }
    if ($fn -notmatch '\$b = Get-Random') { return 'second operand is not random' }
    if ($fn -notmatch '\$answer -ne \[string\]\(\$a \* \$b\)') { return 'answer is not checked against the product' }
    return $true
}

Test-Case 'the gate requires the full DFS path, not just a leaf name' {
    $text = $mainAst.Extent.Text
    $fn = [regex]::Match($text, 'function Confirm-DFSDeletion(.|\n)*?\n\}\n').Value
    if ($fn -notmatch 'Type the FULL path') { return 'no full-path challenge' }
    if ($fn -notmatch '\$typed -ne \(\[string\]\$target\)') { return 'typed value is not compared to the DFS path' }
    if ($fn -match 'Split-Path -Leaf') { return 'gate accepts a leaf name instead of the full path' }
    return $true
}

Test-Case 'a failed challenge is recorded as refused, not silently skipped' {
    $text = $mainAst.Extent.Text
    if ($text -notmatch "Refused: operator confirmation failed") { return 'refusal is not written to the row outcome' }
    return $true
}

Test-Case 'passing the gate suppresses the numb per-object prompts but keeps -WhatIf' {
    $text = $mainAst.Extent.Text
    if ($text -notmatch '\[switch\]\$ChallengePassed') { return 'no ChallengePassed switch' }
    if ($text -notmatch "if \(\`$ChallengePassed\) \{ \`$ConfirmPreference = 'None' \}") {
        return 'prompts are not suppressed after the gate — [A] Yes to All stays reachable'
    }
    # ShouldProcess must still be CALLED, or -WhatIf stops working.
    if ($text -notmatch '\$PSCmdlet\.ShouldProcess') { return 'ShouldProcess removed — -WhatIf would break' }
    return $true
}

Write-Host "`n=== 11. Unattended deletion override manifest ===" -ForegroundColor Cyan

Test-Case '-Force alone does not authorise deletion' {
    $text = $mainAst.Extent.Text
    if ($text -notmatch '-Force does NOT authorise deletion on its own') { return 'no warning that -Force is insufficient' }
    $fn = [regex]::Match($text, 'function Confirm-DFSDeletion(.|\n)*?\n\}\n').Value
    if ($fn -match '\$Force') { return 'gate still consults -Force' }
    return $true
}

Test-Case 'the manifest must be dated today' {
    $text = $mainAst.Extent.Text
    $fn = [regex]::Match($text, 'function Import-DFSOverrideManifest(.|\n)*?\n\}\n').Value
    if (-not $fn) { return 'validator missing' }
    if ($fn -notmatch "\(Get-Date\)\.ToString\('yyyy-MM-dd'\)") { return 'today is never computed' }
    if ($fn -notmatch '\$stated -ne \$today') { return 'date is not compared to today' }
    return $true
}

Test-Case 'SAFETY the manifest must name the account actually running' {
    $text = $mainAst.Extent.Text
    $fn = [regex]::Match($text, 'function Import-DFSOverrideManifest(.|\n)*?\n\}\n').Value
    if ($fn -notmatch 'WindowsIdentity\]::GetCurrent\(\)\.Name') { return 'current identity is never read' }
    if ($fn -notmatch '\$opShort -ine \$meShort') { return 'operator is not compared to the running account' }
    return $true
}

Test-Case 'SAFETY every path opts in individually — no wildcard' {
    $text = $mainAst.Extent.Text
    $fn = [regex]::Match($text, 'function Import-DFSOverrideManifest(.|\n)*?\n\}\n').Value
    if ($fn -notmatch "\[string\]\`$p\.Value -ceq 'OVERRIDE'") { return 'per-path OVERRIDE value is not required' }
    foreach ($bad in @("'\*'", "'ALL'", "'any'")) {
        if ($fn -match [regex]::Escape($bad)) { return "wildcard/all keyword present ($bad)" }
    }
    # An unlisted path must fall through to the interactive challenge, not be allowed.
    $gate = [regex]::Match($text, 'function Confirm-DFSDeletion(.|\n)*?\n\}\n').Value
    if ($gate -notmatch 'NOT listed in the override manifest') { return 'unlisted paths are not rejected' }
    return $true
}

Test-Case 'the OVERRIDE keyword is case-sensitive' {
    $text = $mainAst.Extent.Text
    $fn = [regex]::Match($text, 'function Import-DFSOverrideManifest(.|\n)*?\n\}\n').Value
    if ($fn -notmatch "\`$m\.Override -cne 'OVERRIDE'") { return 'top-level keyword compared case-insensitively' }
    return $true
}

Test-Case 'a rejected manifest aborts the run instead of falling back silently' {
    $text = $mainAst.Extent.Text
    if ($text -notmatch 'was rejected — see the errors above') { return 'no abort on a bad manifest' }
    return $true
}

Write-Host "`n=== 12. -ForceDeletePath (deletion on a person's authority) ===" -ForegroundColor Cyan

Test-Case '-ForceDeletePath skips the evidence check only' {
    $text = $mainAst.Extent.Text
    if ($text -notmatch '\[string\[\]\]\$ForceDeletePath') { return 'parameter missing' }
    if ($text -notmatch 'skipping the verdict/Approved requirement') { return 'evidence check is not bypassed' }
    # The safety refusals must remain reachable — they live in Remove-DFSTarget, which is still called.
    if ($text -notmatch 'is in ProtectedVolumes') { return 'protected-volume refusal gone' }
    if ($text -notmatch 'but was classified as a qtree') { return 'sub-path refusal gone' }
    return $true
}

Test-Case '-ForceDeletePath is rejected outside Delete mode' {
    $text = $mainAst.Extent.Text
    if ($text -notmatch "-ForceDeletePath is only valid with -Mode Delete") { return 'no mode guard' }
    return $true
}

Test-Case 'a forced target still faces the interactive challenge, plus a 4th step' {
    $text = $mainAst.Extent.Text
    $fn = [regex]::Match($text, 'function Confirm-DFSDeletion(.|\n)*?\n\}\n').Value
    if ($fn -notmatch '\[switch\]\$ManagerAuthorised') { return 'no ManagerAuthorised switch' }
    if ($fn -notmatch '\$total = if \(\$ManagerAuthorised\) \{ 4 \} else \{ 3 \}') { return 'step count not raised to 4' }
    if ($fn -notmatch 'Who authorised this deletion') { return 'no authoriser challenge' }
    if ($fn -notmatch "AuthorisedBy") { return 'authoriser is not recorded on the row' }
    return $true
}

Test-Case 'SAFETY the override manifest cannot authorise a forced target' {
    $text = $mainAst.Extent.Text
    $fn = [regex]::Match($text, 'function Confirm-DFSDeletion(.|\n)*?\n\}\n').Value
    if ($fn -notmatch 'if \(\$Override -and \$ManagerAuthorised\)') { return 'manifest is not excluded for forced targets' }
    if ($fn -notmatch 'does not apply to a -ForceDeletePath target') { return 'no explanation logged' }
    return $true
}

Test-Case 'the authoriser is written into the run outcome' {
    $text = $mainAst.Extent.Text
    if ($text -notmatch 'Processed \(ForceDeletePath, authorised by:') { return 'outcome does not record the authoriser' }
    return $true
}

Test-Case 'a force-only run does not demand a VerdictFile, a mixed run does' {
    $text = $mainAst.Extent.Text
    if ($text -notmatch '\$needsEvidence = @\(\$paths \| Where-Object') { return 'evidence-needing targets are not separated' }
    if ($text -notmatch 'if \(\$needsEvidence\.Count -gt 0\)') { return 'VerdictFile is demanded unconditionally' }
    # And a null VerdictFile must never reach Test-Path.
    if ($text -notmatch 'if \(\$VerdictFile\) \{') { return 'VerdictFile load is not guarded against null' }
    return $true
}

Test-Case 'force paths join the target list so a force-only run is not empty' {
    $text = $mainAst.Extent.Text
    if ($text -notmatch '\$explicit = @\(\$Path\) \+ @\(\$ForceDeletePath\)') { return 'force paths are not folded into the explicit list' }
    if ($text -notmatch 'Get-TargetPaths -Cfg \$cfg -Explicit \$explicit') { return 'explicit list is not passed through' }
    return $true
}

Write-Host "`n=== 13. Symlink_Map and Anomalies are rebuilt every run ===" -ForegroundColor Cyan

Test-Case 'Report rebuilds both output sheets' {
    $text = $mainAst.Extent.Text
    if ($text -notmatch 'function Set-DFSWorkbookSheet') { return 'sheet writer missing' }
    if ($text -notmatch "WorksheetName 'Symlink_Map'") { return 'Symlink_Map is never written' }
    if ($text -notmatch "WorksheetName 'Anomalies'") { return 'Anomalies is never written' }
    if ($text -notmatch 'function Get-DFSSymlinkMapAndAnomalies') { return 'row builder missing' }
    return $true
}

Test-Case 'the output sheets are REPLACED, not appended' {
    $text = $mainAst.Extent.Text
    if ($text -notmatch '-ClearSheet') {
        return 'no -ClearSheet — a run with fewer rows would leave stale symlinks behind'
    }
    return $true
}

Test-Case 'SAFETY an empty result never wipes a good sheet' {
    $text = $mainAst.Extent.Text
    $fn = [regex]::Match($text, 'function Set-DFSWorkbookSheet(.|\n)*?\n\}\n').Value
    if (-not $fn) { return 'could not isolate the writer' }
    if ($fn -notmatch 'if \(-not \$Rows -or \$Rows\.Count -eq 0\)') { return 'empty input is not detected' }
    if ($fn -notmatch 'left untouched rather than emptied') { return 'empty input still clears the sheet' }
    return $true
}

Test-Case 'the tab order survives a rebuild' {
    $text = $mainAst.Extent.Text
    $fn = [regex]::Match($text, 'function Set-DFSWorkbookSheet(.|\n)*?\n\}\n').Value
    if ($fn -notmatch 'MoveAfter') { return 'sheet is never moved back — -ClearSheet leaves it last' }
    if ($fn -notmatch 'MoveToStart') { return 'a first-position sheet cannot be restored' }
    return $true
}

Test-Case 'the container scan is reused, not repeated' {
    $text = $mainAst.Extent.Text
    if ($text -notmatch '\$script:SymlinkContainers = @\(\$all') { return 'container scan is not cached' }
    $fn = [regex]::Match($text, 'function Get-DFSSymlinkMapAndAnomalies(.|\n)*?\n\}\n').Value
    if ($fn -match 'Find-NaDFSContainerVolumes') { return 'builder rescans the cluster — doubles the slowest step' }
    if ($fn -notmatch '\$script:SymlinkContainers') { return 'builder does not use the cached scan' }
    return $true
}

Test-Case 'resolution logic is shared, not duplicated' {
    $mod = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\dfs-cleanup\Get-DFSCleanupAnalytics.psm1') -Raw
    if ($mod -notmatch 'function Resolve-NaSymlinkChain') { return 'shared resolver missing from the module' }
    if ($mod -notmatch "'Resolve-NaSymlinkChain'") { return 'resolver not exported' }
    if ($mod -notmatch "'Get-DFSAnomaly'") { return 'anomaly collector not exported' }
    $find = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\dfs-cleanup\Find-NcSymlinkFile.ps1') -Raw
    if ($find -notmatch 'Resolve-NaSymlinkChain') { return 'Find-NcSymlinkFile still has its own copy of the chain logic' }
    if ($find -match "TargetKind\s*=\s*if\s*\(\`$parts\.Count") { return 'duplicated classification left behind in Find-NcSymlinkFile' }
    return $true
}

Test-Case 'a qtree is verified, never inferred from the name' {
    Import-Module (Join-Path $PSScriptRoot '..\dfs-cleanup\Get-DFSCleanupAnalytics.psm1') -Force
    $c = @([PSCustomObject]@{ Volume = 'ROOT'; Uuid = 'u'; Symlinks = @(
        [PSCustomObject]@{ Name = 'L'; FilePath = 'L'; Target = '/L/'; ParentPath = $null; Size = 0 }) })
    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    # 'lookalike_Q' LOOKS like a qtree but is absent from the qtree table.
    $m = @(Resolve-NaSymlinkChain -Containers $c -WidelinkMap @{ 'l' = 'L$' } `
             -ShareMap @{ 'L$' = [PSCustomObject]@{ Path = '/vol1/lookalike_Q' } } -QtreeSet $set)
    if ($m[0].TargetKind -ne 'Directory') { return "name-only qtree became '$($m[0].TargetKind)' — a qtree delete would take siblings" }
    [void]$set.Add('vol1/lookalike_Q')
    $m2 = @(Resolve-NaSymlinkChain -Containers $c -WidelinkMap @{ 'l' = 'L$' } `
              -ShareMap @{ 'L$' = [PSCustomObject]@{ Path = '/vol1/lookalike_Q' } } -QtreeSet $set)
    if ($m2[0].TargetKind -ne 'Qtree') { return 'a real qtree was not recognised' }
    return $true
}

Test-Case 'anomalies cover every shape that has bitten us, worst first' {
    Import-Module (Join-Path $PSScriptRoot '..\dfs-cleanup\Get-DFSCleanupAnalytics.psm1') -Force
    $map = @(
        [PSCustomObject]@{ Volume='A'; FilePath='x'; Target='/dup/'; TargetKey='dup'; IsWidelink=$true;  Share='S$'; TargetPath='/v/q'; TargetQtree='q'; TargetKind='Qtree';     Nested=$false }
        [PSCustomObject]@{ Volume='B'; FilePath='x'; Target='/dup/'; TargetKey='dup'; IsWidelink=$true;  Share='S$'; TargetPath='/v/q'; TargetQtree='q'; TargetKind='Qtree';     Nested=$false }
        [PSCustomObject]@{ Volume='A'; FilePath='d'; Target='/dir/'; TargetKey='dir'; IsWidelink=$true;  Share='D$'; TargetPath='/v/f/g'; TargetQtree='f'; TargetKind='Directory'; Nested=$false }
        [PSCustomObject]@{ Volume='A'; FilePath='p'; Target='/x/y';  TargetKey='x/y'; IsWidelink=$false; Share=$null; TargetPath=$null; TargetQtree=$null; TargetKind=$null;      Nested=$true }
    )
    $wl = @{ 'dup' = 'S$'; 'dir' = 'D$'; 'multi1' = 'M$'; 'multi2' = 'M$' }
    $a = @(Get-DFSAnomaly -SymlinkMap $map -WidelinkMap $wl)
    $types = @($a | ForEach-Object { $_.Type })
    foreach ($t in @('Several WIDELINKS -> one share', 'Share targets a DIRECTORY, not a qtree',
                     'Several symlink FILES -> one widelink', 'Widelink with no symlink file',
                     'Plain UNIX symlink (not DFS)', 'Symlink file below the volume root')) {
        if ($types -notcontains $t) { return "missing anomaly type: $t" }
    }
    if ($a[0].Severity -ne 'DO NOT DELETE') { return 'not sorted worst-first' }
    if (@(Get-DFSAnomaly -SymlinkMap @() -WidelinkMap @{}).Count -ne 0) { return 'empty input produced anomalies' }
    return $true
}

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "  Passed: $pass" -ForegroundColor Green
if ($fail -gt 0) {
    Write-Host "  Failed: $fail" -ForegroundColor Red
    exit 1
}
Write-Host "  All offline checks passed." -ForegroundColor Green
