<#
.SYNOPSIS
    Debug harness — runs all Share Migration modes and captures results to debug/
.DESCRIPTION
    Iterates through every Share Migration mode (except ResetCifsPassword),
    runs each one with full transcript capture, and writes a summary log.

    Interactive/GUI scripts (Start-ShareMigManager, New-ShareMigConfig) are
    syntax-checked only — they are not launched.

    All output goes to debug/ (gitignored).
.EXAMPLE
    .\Test-ShareMigScripts.ps1
    .\Test-ShareMigScripts.ps1 -SkipModes DomainMigration,Rollback
#>
[CmdletBinding()]
param(
    [string[]]$SkipModes = @()
)

$ErrorActionPreference = 'Stop'
$workspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$timestamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
$debugDir      = Join-Path $workspaceRoot 'debug'
$logFile       = Join-Path $debugDir "sharemig-test-$timestamp.log"

# Ensure debug/ exists
if (-not (Test-Path $debugDir)) { New-Item -ItemType Directory -Path $debugDir -Force | Out-Null }

# ── Logging helper ──────────────────────────────────────────────────────────
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','PASS','FAIL','WARN','SKIP')] [string]$Level = 'INFO'
    )
    $colors = @{ INFO = 'White'; PASS = 'Green'; FAIL = 'Red'; WARN = 'Yellow'; SKIP = 'DarkYellow' }
    $line = "[$(Get-Date -Format 'HH:mm:ss')] [$Level] $Message"
    Write-Host $line -ForegroundColor $colors[$Level]
    Add-Content -LiteralPath $logFile -Value $line
}

# ── Test definitions ────────────────────────────────────────────────────────
$invokeScript = Join-Path $workspaceRoot 'scripts\share-migration\Invoke-ShareMigration.ps1'
$editScript   = Join-Path $workspaceRoot 'scripts\share-migration\Start-ShareMigManager.ps1'
$wizardScript = Join-Path $workspaceRoot 'scripts\share-migration\New-ShareMigConfig.ps1'

$tests = @(
    @{ Name = 'Export';           Args = '-Mode Export' }
    @{ Name = 'Import';           Args = '-Mode Import' }
    @{ Name = 'Preflight';        Args = '-Mode Preflight -ApprovePreflight' }
    @{ Name = 'Sync';             Args = '-Mode Sync' }
    @{ Name = 'DomainMigration';  Args = '-Mode DomainMigration' }
    @{ Name = 'TestCredentials';  Args = '-Mode TestCredentials -Target Both' }
    @{ Name = 'Rollback';         Args = '-Mode Rollback' }
)

# ── Results collector ───────────────────────────────────────────────────────
$results = [System.Collections.Generic.List[pscustomobject]]::new()

# ── Banner ──────────────────────────────────────────────────────────────────
Write-Log '═══════════════════════════════════════════════════════════'
Write-Log "Share Migration Debug Harness — $timestamp"
Write-Log "Workspace : $workspaceRoot"
Write-Log "Log file  : $logFile"
Write-Log '═══════════════════════════════════════════════════════════'

# ── Phase 1: Syntax checks on interactive scripts ───────────────────────────
Write-Log ''
Write-Log '── Phase 1: Syntax Validation ──'

foreach ($scriptPath in @($invokeScript, $editScript, $wizardScript)) {
    $scriptName = Split-Path $scriptPath -Leaf
    $errors = $null
    [System.Management.Automation.PSParser]::Tokenize(
        (Get-Content -Raw -LiteralPath $scriptPath), [ref]$errors
    ) | Out-Null

    if ($errors.Count -gt 0) {
        Write-Log "$scriptName — SYNTAX ERROR" -Level FAIL
        foreach ($e in $errors) {
            $detail = "  Line $($e.Token.StartLine): $($e.Message)"
            Write-Log $detail -Level FAIL
        }
        $results.Add([pscustomobject]@{
            Test     = "Syntax: $scriptName"
            Status   = 'FAIL'
            Duration = '-'
            Error    = ($errors | ForEach-Object { "Line $($_.Token.StartLine): $($_.Message)" }) -join '; '
        })
    }
    else {
        Write-Log "$scriptName — OK" -Level PASS
        $results.Add([pscustomobject]@{
            Test     = "Syntax: $scriptName"
            Status   = 'PASS'
            Duration = '-'
            Error    = ''
        })
    }
}

# ── Phase 2: Run each Invoke-ShareMigration mode ───────────────────────────
Write-Log ''
Write-Log '── Phase 2: Mode Execution ──'

foreach ($test in $tests) {
    $modeName = $test.Name

    if ($modeName -in $SkipModes) {
        Write-Log "$modeName — SKIPPED (user request)" -Level SKIP
        $results.Add([pscustomobject]@{
            Test     = "Mode: $modeName"
            Status   = 'SKIP'
            Duration = '-'
            Error    = 'Skipped by -SkipModes'
        })
        continue
    }

    Write-Log ''
    Write-Log "▶ Running: $modeName ($($test.Args))"

    $transcriptFile = Join-Path $debugDir "transcript-$modeName-$timestamp.log"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $testError = $null

    try {
        Start-Transcript -Path $transcriptFile -Force | Out-Null
        $expression = "& '$invokeScript' $($test.Args)"
        Invoke-Expression $expression
        Stop-Transcript | Out-Null
    }
    catch {
        $testError = $_
        try { Stop-Transcript | Out-Null } catch {}
    }

    $sw.Stop()
    $duration = '{0:mm\:ss\.ff}' -f $sw.Elapsed

    if ($testError) {
        Write-Log "$modeName — FAILED ($duration)" -Level FAIL
        Write-Log "  Error: $($testError.Exception.Message)" -Level FAIL
        if ($testError.ScriptStackTrace) {
            Write-Log "  Stack: $($testError.ScriptStackTrace -split "`n" | Select-Object -First 3 | ForEach-Object { $_.Trim() })" -Level FAIL
        }
        # Append error detail to the mode's transcript
        Add-Content -LiteralPath $transcriptFile -Value "`n=== ERROR ===`n$($testError | Out-String)"

        $results.Add([pscustomobject]@{
            Test     = "Mode: $modeName"
            Status   = 'FAIL'
            Duration = $duration
            Error    = $testError.Exception.Message
        })
    }
    else {
        Write-Log "$modeName — PASSED ($duration)" -Level PASS
        $results.Add([pscustomobject]@{
            Test     = "Mode: $modeName"
            Status   = 'PASS'
            Duration = $duration
            Error    = ''
        })
    }

    Write-Log "  Transcript: $transcriptFile"
}

# ── Summary ─────────────────────────────────────────────────────────────────
Write-Log ''
Write-Log '═══════════════════════════════════════════════════════════'
Write-Log '                     SUMMARY'
Write-Log '═══════════════════════════════════════════════════════════'

$pass = ($results | Where-Object Status -eq 'PASS').Count
$fail = ($results | Where-Object Status -eq 'FAIL').Count
$skip = ($results | Where-Object Status -eq 'SKIP').Count

$results | Format-Table -AutoSize -Property Test, Status, Duration, Error | Out-String | ForEach-Object {
    Write-Log $_
}

Write-Log "Total: $($results.Count) | Pass: $pass | Fail: $fail | Skip: $skip"

if ($fail -gt 0) {
    Write-Log 'Some tests FAILED — check transcripts in debug/' -Level WARN
}
else {
    Write-Log 'All tests passed!' -Level PASS
}

Write-Log "Full log: $logFile"
