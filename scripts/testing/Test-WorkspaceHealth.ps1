<#
.SYNOPSIS
    Comprehensive workspace health check — validates all scripts, skills, dependencies, and connectivity.
.DESCRIPTION
    Non-destructive test suite that validates:
    - PowerShell script syntax (all .ps1 files parse without errors)
    - Config loading and auto-generated cluster functions
    - Module availability (NetApp.ONTAP, DataONTAP, personal modules)
    - Credential store integrity (aes.key + .cred files decrypt OK)
    - External tool availability (ssh, git, python, wsl, aws, rclone)
    - Skill file integrity (all 12 SKILL.md files present)
    - Knowledge base files (Netapp Cases, KnownIssues, PDFs)
    - SSH connectivity to all clusters (version command only)
    - ZAPI connectivity to all clusters (Connect-NcController)
    - S3 config completeness (clusters, credentials, vault files)
    - Ansible playbooks, vault files, syntax validation, collection
    - DFS config completeness (Vserver, CifsServer, DfsShare, Domain)
    - NDMP config completeness (clusters, passwords, paths)
    - Git repository health (branches, remotes, working tree)
    - Docs hub (port, index.html)
    - CSV CLI smoke test (end-to-end Invoke-OntapCsv)
    - REST API smoke test (/api/cluster)
    - Config template drift (config.json keys vs config.template.json)
    - Session log recency (.github/session-log-*.md freshness)
    - Cluster operational health per cluster:
        SVM state, node health, aggregate/volume utilization,
        SnapMirror health & lag, cluster faults, storage errors,
        snapshot policies, iSCSI sessions, LIF home port status,
        HA failover, disk health, cluster peers, network ports,
        S3 server status (conditional)

    Outputs: transcript log + CSV report + colorized console summary.
.PARAMETER OutputDir
    Directory for log and CSV output. Default: scripts/testing/logs
.PARAMETER SkipConnectivity
    Skip SSH and ZAPI cluster connectivity tests (fast mode).
.PARAMETER SkipCredentials
    Skip credential store decryption tests.
.EXAMPLE
    .\Test-WorkspaceHealth.ps1
    # Full test — syntax, config, modules, credentials, connectivity, skills
.EXAMPLE
    .\Test-WorkspaceHealth.ps1 -SkipConnectivity
    # Fast mode — no cluster connectivity tests
.EXAMPLE
    .\Test-WorkspaceHealth.ps1 -SkipConnectivity -SkipCredentials
    # Offline mode — only local file/syntax/config checks
.EXAMPLE
    .\Test-WorkspaceHealth.ps1 -Cluster <ClusterName> -AggWarnPct 75
    # Full check on a single cluster with custom aggregate threshold
#>
[CmdletBinding()]
param(
    [string]$OutputDir,
    [switch]$SkipConnectivity,
    [switch]$SkipCredentials,
    [string]$Cluster,
    [int]$AggWarnPct       = 80,
    [int]$AggFailPct       = 90,
    [int]$VolWarnPct       = 85,
    [int]$VolFailPct       = 95,
    [int]$SnapLagWarnHours = 24,
    [int]$SnapLagFailHours = 48
)

$ErrorActionPreference = 'Continue'
$rootDir = (Resolve-Path "$PSScriptRoot\..\..").Path
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

# ============================================================
# Output directory
# ============================================================
if (-not $OutputDir) { $OutputDir = Join-Path $PSScriptRoot 'logs' }
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

$logFile = Join-Path $OutputDir "WorkspaceHealth_$timestamp.log"
$csvFile = Join-Path $OutputDir "WorkspaceHealth_$timestamp.csv"

# ============================================================
# Start transcript
# ============================================================
Start-Transcript -Path $logFile -Force | Out-Null

Write-Host "`n╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host   "║          ONTAP Workspace Health Check — $timestamp        ║" -ForegroundColor Cyan
Write-Host   "╚══════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan
Write-Host "Root directory : $rootDir"
Write-Host "Output dir     : $OutputDir"
Write-Host "Transcript     : $logFile"
Write-Host "CSV report     : $csvFile`n"

# ============================================================
# Results collector
# ============================================================
$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-TestResult {
    param(
        [string]$Category,
        [string]$TestName,
        [ValidateSet('Pass','Fail','Warn','Skip')]
        [string]$Status,
        [string]$Message = '',
        [long]$DurationMs = 0
    )
    $color = switch ($Status) {
        'Pass' { 'Green'  }
        'Fail' { 'Red'    }
        'Warn' { 'Yellow' }
        'Skip' { 'DarkGray' }
    }
    $icon = switch ($Status) {
        'Pass' { '[PASS]' }
        'Fail' { '[FAIL]' }
        'Warn' { '[WARN]' }
        'Skip' { '[SKIP]' }
    }
    Write-Host "  $icon $Category / $TestName" -ForegroundColor $color -NoNewline
    if ($Message) { Write-Host " — $Message" -ForegroundColor DarkGray } else { Write-Host '' }
    $script:results.Add([PSCustomObject]@{
        Category   = $Category
        TestName   = $TestName
        Status     = $Status
        Message    = $Message
        DurationMs = $DurationMs
    })
}

# ============================================================
# Helpers: SSH runner & duration parser (for cluster ops phases)
# ============================================================
function Invoke-ClusterSsh {
    param([string]$Host_, [string]$Cmd, [int]$TimeoutSec = 30)
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        # Pass arguments as a single string to avoid Start-Process quoting
        # individual array elements (ONTAP SSH doesn't handle quoted commands)
        $arguments = "-o ConnectTimeout=$TimeoutSec -o BatchMode=yes -o StrictHostKeyChecking=no -o ServerAliveInterval=10 -o ServerAliveCountMax=2 admin@$Host_ $Cmd"
        $proc = Start-Process -FilePath 'ssh' -ArgumentList $arguments `
            -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $exited = $proc.WaitForExit($TimeoutSec * 1000)
        if ($exited) {
            $output = @(Get-Content $outFile -ErrorAction SilentlyContinue)
            return $output, $proc.ExitCode
        } else {
            try { $proc.Kill() } catch {}
            return @("ERROR: SSH command timed out after ${TimeoutSec}s"), 124
        }
    } catch {
        return @("ERROR: $($_.Exception.Message)"), 1
    } finally {
        Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-OntapDataLines {
    # Strip SSH banners and headers — returns only data lines after the '---' separator
    param([string[]]$Lines)
    $sepIdx = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^\s*-{3,}') { $sepIdx = $i; break }
    }
    if ($sepIdx -ge 0 -and ($sepIdx + 1) -lt $Lines.Count) {
        return @($Lines[($sepIdx + 1)..($Lines.Count - 1)])
    }
    return @()
}

function ConvertTo-Hours {
    param([string]$Duration)
    if ($Duration -match 'P(\d+)DT(\d+)H(\d+)M(\d+)S') {
        return [int]$Matches[1] * 24 + [int]$Matches[2]
    }
    if ($Duration -match '(\d+):(\d+):(\d+)') {
        return [int]$Matches[1]
    }
    return -1
}

# ============================================================
# PHASE 1: Script Syntax Validation
# ============================================================
Write-Host "`n── Phase 1: Script Syntax Validation ──────────────────────────" -ForegroundColor White

$scriptsToValidate = @(
    @{ Name = 'Load-Config.ps1';                       Path = "$rootDir\Load-Config.ps1" }
    @{ Name = 'profile1.ps1';                          Path = "$rootDir\profile1.ps1" }
    @{ Name = 'Start-Docs.ps1';                        Path = "$rootDir\Start-Docs.ps1" }
    @{ Name = 'Switch-Branch.ps1';                     Path = "$rootDir\Switch-Branch.ps1" }
    @{ Name = 'scripts\credentials\Get-Credential.ps1'; Path = "$rootDir\scripts\credentials\Get-Credential.ps1" }
    @{ Name = 'scripts\credentials\New-Credential.ps1'; Path = "$rootDir\scripts\credentials\New-Credential.ps1" }
    @{ Name = 'scripts\disk\sas-diag.ps1';             Path = "$rootDir\scripts\disk\sas-diag.ps1" }
    @{ Name = 'scripts\snapshots\Get-BiggestSnapshot.ps1';    Path = "$rootDir\scripts\snapshots\Get-BiggestSnapshot.ps1" }
    @{ Name = 'scripts\reports\Get-DR-Report.ps1';     Path = "$rootDir\scripts\reports\Get-DR-Report.ps1" }
    @{ Name = 'scripts\snapmirror\Monitor-SnapMirror.ps1';   Path = "$rootDir\scripts\snapmirror\Monitor-SnapMirror.ps1" }
    @{ Name = 'scripts\ndmp-copy\Ndmp_Copy.ps1';       Path = "$rootDir\scripts\ndmp-copy\Ndmp_Copy.ps1" }
    @{ Name = 'scripts\quota\Clusters Quota Policy Manger.ps1'; Path = "$rootDir\scripts\quota\Clusters Quota Policy Manger.ps1" }
    @{ Name = 'scripts\testing\Test-NetappROUser.ps1';  Path = "$rootDir\scripts\testing\Test-NetappROUser.ps1" }
    @{ Name = 'scripts\testing\Test-VserverConfigOverrideAPI.ps1'; Path = "$rootDir\scripts\testing\Test-VserverConfigOverrideAPI.ps1" }
    @{ Name = 'scripts\testing\Test-WorkspaceHealth.ps1';        Path = "$rootDir\scripts\testing\Test-WorkspaceHealth.ps1" }
    @{ Name = 'ansible\s3-bucket-provision\Invoke-S3Provision.ps1'; Path = "$rootDir\ansible\s3-bucket-provision\Invoke-S3Provision.ps1" }
    @{ Name = 'scripts\WSL\Setup-AnsibleWSL.ps1';              Path = "$rootDir\scripts\WSL\Setup-AnsibleWSL.ps1" }
)

foreach ($script in $scriptsToValidate) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    if (-not (Test-Path $script.Path)) {
        Add-TestResult -Category 'Syntax' -TestName $script.Name -Status 'Fail' -Message "File not found: $($script.Path)" -DurationMs $sw.ElapsedMilliseconds
        continue
    }
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($script.Path, [ref]$tokens, [ref]$errors) | Out-Null
    $sw.Stop()
    if ($errors.Count -eq 0) {
        Add-TestResult -Category 'Syntax' -TestName $script.Name -Status 'Pass' -Message 'No parse errors' -DurationMs $sw.ElapsedMilliseconds
    } else {
        $errMsg = ($errors | Select-Object -First 3 | ForEach-Object { $_.Message }) -join '; '
        Add-TestResult -Category 'Syntax' -TestName $script.Name -Status 'Fail' -Message "$($errors.Count) error(s): $errMsg" -DurationMs $sw.ElapsedMilliseconds
    }
}

# Check ndmp-copy.bat exists (batch, can't parse as PS)
$batPath = "$rootDir\scripts\ndmp-copy\ndmp-copy.bat"
if (Test-Path $batPath) {
    Add-TestResult -Category 'Syntax' -TestName 'scripts\ndmp-copy\ndmp-copy.bat' -Status 'Pass' -Message 'File exists'
} else {
    Add-TestResult -Category 'Syntax' -TestName 'scripts\ndmp-copy\ndmp-copy.bat' -Status 'Fail' -Message 'File not found'
}

# Ansible YAML playbooks — validate they parse as valid YAML
$ansibleYmls = @(
    'ansible\s3-bucket-provision\provision_s3_bucket.yml'
    'ansible\s3-bucket-provision\provision_s3_bucket_admin.yml'
    'ansible\s3-bucket-provision\provision_s3_bucket_dev.yml'
    'ansible\s3-bucket-provision\provision_s3_bucket_generic.yml'
)
foreach ($yml in $ansibleYmls) {
    $ymlPath = Join-Path $rootDir $yml
    if (-not (Test-Path $ymlPath)) {
        Add-TestResult -Category 'Syntax' -TestName $yml -Status 'Fail' -Message 'File not found'
        continue
    }
    try {
        # Basic YAML structure check — must start with '---' or valid YAML content
        $content = Get-Content $ymlPath -Raw -ErrorAction Stop
        if ($content.Length -eq 0) {
            Add-TestResult -Category 'Syntax' -TestName $yml -Status 'Fail' -Message 'File is empty'
        } elseif ($content -match '^\s*---' -or $content -match '^\s*-\s+') {
            Add-TestResult -Category 'Syntax' -TestName $yml -Status 'Pass' -Message "YAML file $('{0:N0}' -f $content.Length) bytes"
        } else {
            Add-TestResult -Category 'Syntax' -TestName $yml -Status 'Warn' -Message 'File does not start with --- or list marker'
        }
    } catch {
        Add-TestResult -Category 'Syntax' -TestName $yml -Status 'Fail' -Message $_.Exception.Message
    }
}

# Ansible SVM-management playbook directory (may have .gitkeep only)
$svmMgmtDir = Join-Path $rootDir 'ansible\svm-management'
if (Test-Path $svmMgmtDir) {
    Add-TestResult -Category 'Syntax' -TestName 'ansible\svm-management\' -Status 'Pass' -Message 'Directory exists (placeholder)'
}

# ============================================================
# PHASE 2: Configuration & Bootstrap
# ============================================================
Write-Host "`n── Phase 2: Configuration & Bootstrap ─────────────────────────" -ForegroundColor White

$configLoaded = $false
$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    . "$rootDir\Load-Config.ps1"
    $sw.Stop()
    $configLoaded = $true
    Add-TestResult -Category 'Config' -TestName 'Load-Config.ps1' -Status 'Pass' -Message 'Config loaded successfully' -DurationMs $sw.ElapsedMilliseconds
} catch {
    $sw.Stop()
    Add-TestResult -Category 'Config' -TestName 'Load-Config.ps1' -Status 'Fail' -Message $_.Exception.Message -DurationMs $sw.ElapsedMilliseconds
}

if ($configLoaded) {
    # Validate $Config object
    if ($global:Config) {
        Add-TestResult -Category 'Config' -TestName '$Config populated' -Status 'Pass' -Message "Type: $($global:Config.GetType().Name)"
    } else {
        Add-TestResult -Category 'Config' -TestName '$Config populated' -Status 'Fail' -Message '$global:Config is null'
    }

    # Validate ONTAP_Clusters
    if ($global:ONTAP_Clusters -and $global:ONTAP_Clusters.Count -gt 0) {
        Add-TestResult -Category 'Config' -TestName 'ONTAP_Clusters' -Status 'Pass' -Message "$($global:ONTAP_Clusters.Count) cluster(s) loaded"
    } else {
        Add-TestResult -Category 'Config' -TestName 'ONTAP_Clusters' -Status 'Fail' -Message 'No clusters loaded'
    }

    # Validate each cluster has required properties
    foreach ($cl in $global:ONTAP_Clusters) {
        $missing = @()
        if (-not $cl.ClusterName)  { $missing += 'ClusterName' }
        if (-not $cl.ConnectName)  { $missing += 'ConnectName' }
        if (-not $cl.CsvPrefix)    { $missing += 'CsvPrefix' }
        if ($missing.Count -gt 0) {
            Add-TestResult -Category 'Config' -TestName "Cluster: $($cl.ClusterName ?? $cl.ConnectName ?? '(unknown)')" -Status 'Fail' -Message "Missing: $($missing -join ', ')"
        } else {
            Add-TestResult -Category 'Config' -TestName "Cluster: $($cl.ClusterName)" -Status 'Pass' -Message "Connect=$($cl.ConnectName) CSV=$($cl.CsvPrefix) IP=$($cl.FallbackIP ?? 'DNS')"
        }
    }

    # Validate ONTAP_ROUser
    if ($global:ONTAP_ROUser) {
        Add-TestResult -Category 'Config' -TestName 'ONTAP_ROUser' -Status 'Pass' -Message $global:ONTAP_ROUser
    } else {
        Add-TestResult -Category 'Config' -TestName 'ONTAP_ROUser' -Status 'Warn' -Message 'Not set — ZAPI connectivity tests will be skipped'
    }

    # Validate auto-generated functions
    Write-Host "`n── Phase 2b: Auto-Generated Functions ─────────────────────────" -ForegroundColor White

    # Global helpers
    foreach ($fn in @('Invoke-OntapCsv', 'Get-OntapTargetClusters')) {
        if (Get-Command $fn -ErrorAction SilentlyContinue) {
            Add-TestResult -Category 'Functions' -TestName $fn -Status 'Pass' -Message 'Function exists'
        } else {
            Add-TestResult -Category 'Functions' -TestName $fn -Status 'Fail' -Message 'Function not found'
        }
    }

    # Per-cluster functions
    foreach ($cl in $global:ONTAP_Clusters) {
        $connectName = $cl.ConnectName
        $csvPrefix   = $cl.CsvPrefix
        $alias       = $cl.Alias

        # Connect function
        if (Get-Command $connectName -ErrorAction SilentlyContinue) {
            Add-TestResult -Category 'Functions' -TestName "$connectName (connect)" -Status 'Pass'
        } else {
            Add-TestResult -Category 'Functions' -TestName "$connectName (connect)" -Status 'Fail' -Message 'Not found'
        }

        # SSH function
        $sshFn = "$connectName-s"
        if (Get-Command $sshFn -ErrorAction SilentlyContinue) {
            Add-TestResult -Category 'Functions' -TestName "$sshFn (SSH)" -Status 'Pass'
        } else {
            Add-TestResult -Category 'Functions' -TestName "$sshFn (SSH)" -Status 'Fail' -Message 'Not found'
        }

        # CSV helper
        if ($csvPrefix) {
            $csvFn = "Get-${csvPrefix}Csv"
            if (Get-Command $csvFn -ErrorAction SilentlyContinue) {
                Add-TestResult -Category 'Functions' -TestName "$csvFn (CSV)" -Status 'Pass'
            } else {
                Add-TestResult -Category 'Functions' -TestName "$csvFn (CSV)" -Status 'Fail' -Message 'Not found'
            }
        }

        # Alias (if different from ConnectName)
        if ($alias -and $alias -ne $connectName) {
            if (Get-Command $alias -ErrorAction SilentlyContinue) {
                Add-TestResult -Category 'Functions' -TestName "$alias (alias)" -Status 'Pass'
            } else {
                Add-TestResult -Category 'Functions' -TestName "$alias (alias)" -Status 'Warn' -Message 'Alias not found'
            }
        }
    }
}

# ============================================================
# PHASE 3: Module Availability
# ============================================================
Write-Host "`n── Phase 3: Module Availability ────────────────────────────────" -ForegroundColor White

# NetApp.ONTAP (required)
$mod = Get-Module -ListAvailable -Name 'NetApp.ONTAP' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($mod) {
    Add-TestResult -Category 'Modules' -TestName 'NetApp.ONTAP' -Status 'Pass' -Message "v$($mod.Version)"
} else {
    Add-TestResult -Category 'Modules' -TestName 'NetApp.ONTAP' -Status 'Fail' -Message 'Module not installed'
}

# DataONTAP (legacy — warn only)
$modLegacy = Get-Module -ListAvailable -Name 'DataONTAP' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($modLegacy) {
    Add-TestResult -Category 'Modules' -TestName 'DataONTAP (legacy)' -Status 'Pass' -Message "v$($modLegacy.Version)"
} else {
    Add-TestResult -Category 'Modules' -TestName 'DataONTAP (legacy)' -Status 'Warn' -Message 'Not installed (optional legacy module)'
}

# Personal modules from config
if ($configLoaded -and $global:Config.Personal_modules) {
    foreach ($modPath in $global:Config.Personal_modules) {
        if (Test-Path $modPath) {
            Add-TestResult -Category 'Modules' -TestName "Personal: $(Split-Path $modPath -Leaf)" -Status 'Pass' -Message $modPath
        } else {
            Add-TestResult -Category 'Modules' -TestName "Personal: $(Split-Path $modPath -Leaf)" -Status 'Warn' -Message "Not found: $modPath"
        }
    }
}

# ============================================================
# PHASE 4: External Tools
# ============================================================
Write-Host "`n── Phase 4: External Tool Availability ─────────────────────────" -ForegroundColor White

$tools = @(
    @{ Name = 'ssh';    Required = $true;  Hint = '' }
    @{ Name = 'git';    Required = $true;  Hint = '' }
    @{ Name = 'wsl';    Required = $false; Hint = '(needed for Ansible playbooks)' }
)

foreach ($tool in $tools) {
    $cmd = Get-Command $tool.Name -ErrorAction SilentlyContinue
    if ($cmd) {
        $ver = ''
        try {
            if ($tool.Name -eq 'git') { $ver = (git --version 2>$null) }
            elseif ($tool.Name -eq 'ssh') { $ver = (ssh -V 2>&1 | Select-Object -First 1) }
        } catch {}
        $status = 'Pass'
        Add-TestResult -Category 'Tools' -TestName $tool.Name -Status $status -Message ($ver ?? $cmd.Source)
    } else {
        $status = if ($tool.Required) { 'Fail' } else { 'Warn' }
        Add-TestResult -Category 'Tools' -TestName $tool.Name -Status $status -Message "Not found $($tool.Hint)"
    }
}

# Python — check multiple locations
$pythonCmd = Get-Command 'python' -ErrorAction SilentlyContinue
$pythonAlt = 'c:\python313\python.exe'
if ($pythonCmd) {
    $pyVer = try { python --version 2>&1 } catch { '' }
    Add-TestResult -Category 'Tools' -TestName 'python' -Status 'Pass' -Message ($pyVer ?? $pythonCmd.Source)
} elseif (Test-Path $pythonAlt) {
    $pyVer = try { & $pythonAlt --version 2>&1 } catch { '' }
    Add-TestResult -Category 'Tools' -TestName 'python' -Status 'Pass' -Message "$pyVer ($pythonAlt)"
} else {
    Add-TestResult -Category 'Tools' -TestName 'python' -Status 'Warn' -Message 'Not found (needed for Start-Docs.ps1 and PDF import)'
}

# Ansible via WSL
if (Get-Command 'wsl' -ErrorAction SilentlyContinue) {
    $ansibleCheck = try { wsl -d Ubuntu-22.04 -- bash --norc --noprofile -c 'export PATH=/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin; which ansible-playbook' 2>&1 } catch { '' }
    if ($ansibleCheck -and $ansibleCheck -notmatch 'not found') {
        Add-TestResult -Category 'Tools' -TestName 'ansible-playbook (WSL)' -Status 'Pass' -Message $ansibleCheck.Trim()
    } else {
        Add-TestResult -Category 'Tools' -TestName 'ansible-playbook (WSL)' -Status 'Warn' -Message 'Not found in WSL (needed for S3 provisioning)'
    }
} else {
    Add-TestResult -Category 'Tools' -TestName 'ansible-playbook (WSL)' -Status 'Skip' -Message 'WSL not available'
}

# ============================================================
# PHASE 5: Credential Store
# ============================================================
Write-Host "`n── Phase 5: Credential Store ───────────────────────────────────" -ForegroundColor White

$credDir = Join-Path $rootDir 'credentials'
$aesKeyPath = Join-Path $credDir 'aes.key'

if ($SkipCredentials) {
    Add-TestResult -Category 'Credentials' -TestName 'Credential Store' -Status 'Skip' -Message 'Skipped by -SkipCredentials'
} else {
    # aes.key
    if (Test-Path $aesKeyPath) {
        Add-TestResult -Category 'Credentials' -TestName 'aes.key' -Status 'Pass' -Message 'Key file exists'
    } else {
        Add-TestResult -Category 'Credentials' -TestName 'aes.key' -Status 'Fail' -Message 'Key file missing — run New-Credential.ps1 first'
    }

    # .cred files
    $credFiles = Get-ChildItem -Path $credDir -Filter '*.cred' -ErrorAction SilentlyContinue
    if ($credFiles.Count -eq 0) {
        Add-TestResult -Category 'Credentials' -TestName '.cred files' -Status 'Warn' -Message 'No credential files found'
    } else {
        Add-TestResult -Category 'Credentials' -TestName '.cred files' -Status 'Pass' -Message "$($credFiles.Count) file(s): $($credFiles.BaseName -join ', ')"

        # Try decrypting each
        if (Test-Path $aesKeyPath) {
            $getCredScript = Join-Path $rootDir 'scripts\credentials\Get-Credential.ps1'
            foreach ($cf in $credFiles) {
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                try {
                    $val = & $getCredScript -Name $cf.BaseName
                    $sw.Stop()
                    if ($val) {
                        Add-TestResult -Category 'Credentials' -TestName "Decrypt: $($cf.BaseName)" -Status 'Pass' -Message 'Decrypted OK (value not logged)' -DurationMs $sw.ElapsedMilliseconds
                    } else {
                        Add-TestResult -Category 'Credentials' -TestName "Decrypt: $($cf.BaseName)" -Status 'Warn' -Message 'Decrypted but empty value' -DurationMs $sw.ElapsedMilliseconds
                    }
                } catch {
                    $sw.Stop()
                    Add-TestResult -Category 'Credentials' -TestName "Decrypt: $($cf.BaseName)" -Status 'Fail' -Message $_.Exception.Message -DurationMs $sw.ElapsedMilliseconds
                }
            }
        }
    }
}

# ============================================================
# PHASE 6: Skill File Integrity
# ============================================================
Write-Host "`n── Phase 6: Skill File Integrity ───────────────────────────────" -ForegroundColor White

$skillsDir = Join-Path $rootDir '.github\skills'
$expectedSkills = @(
    'dfs-management'
    'iscsi-management'
    'ndmp-copy'
    'network-management'
    'ontap-cluster-info'
    'pdf-knowledge-import'
    'quota-management'
    's3-management'
    'snapmirror-management'
    'svm-dr'
    'svm-management'
    'volume-management'
)

if (-not (Test-Path $skillsDir)) {
    Add-TestResult -Category 'Skills' -TestName 'Skills directory' -Status 'Fail' -Message "Not found: $skillsDir"
} else {
    # Check each expected skill
    foreach ($skill in $expectedSkills) {
        $skillMd = Join-Path $skillsDir "$skill\SKILL.md"
        if (-not (Test-Path $skillMd)) {
            Add-TestResult -Category 'Skills' -TestName $skill -Status 'Fail' -Message 'SKILL.md not found'
            continue
        }
        $fileInfo = Get-Item $skillMd
        if ($fileInfo.Length -eq 0) {
            Add-TestResult -Category 'Skills' -TestName $skill -Status 'Fail' -Message 'SKILL.md is empty (0 bytes)'
            continue
        }
        # Check references directory
        $refsDir = Join-Path $skillsDir "$skill\references"
        $refsInfo = ''
        if (Test-Path $refsDir) {
            $refCount = (Get-ChildItem $refsDir -File -ErrorAction SilentlyContinue).Count
            $refsInfo = " | refs: $refCount file(s)"
        }
        Add-TestResult -Category 'Skills' -TestName $skill -Status 'Pass' -Message "SKILL.md $('{0:N0}' -f $fileInfo.Length) bytes$refsInfo"
    }

    # Check for unexpected skill directories
    $actualSkills = Get-ChildItem $skillsDir -Directory | Select-Object -ExpandProperty Name
    $unexpected = $actualSkills | Where-Object { $_ -notin $expectedSkills }
    foreach ($u in $unexpected) {
        Add-TestResult -Category 'Skills' -TestName "$u (unexpected)" -Status 'Warn' -Message 'Skill directory not in expected list — may be new'
    }
}

# ============================================================
# PHASE 7: Knowledge Base Integrity
# ============================================================
Write-Host "`n── Phase 7: Knowledge Base ─────────────────────────────────────" -ForegroundColor White

# Netapp Cases
$casesDir = Join-Path $rootDir '.github\Netapp Cases'
if (Test-Path $casesDir) {
    $caseFiles = Get-ChildItem $casesDir -File -Filter '*.md' -ErrorAction SilentlyContinue
    $emptyFiles = $caseFiles | Where-Object { $_.Length -eq 0 }
    if ($caseFiles.Count -gt 0) {
        $msg = "$($caseFiles.Count) case file(s)"
        if ($emptyFiles.Count -gt 0) { $msg += " ($($emptyFiles.Count) empty!)" }
        Add-TestResult -Category 'KnowledgeBase' -TestName 'Netapp Cases' -Status $(if ($emptyFiles.Count) { 'Warn' } else { 'Pass' }) -Message $msg
    } else {
        Add-TestResult -Category 'KnowledgeBase' -TestName 'Netapp Cases' -Status 'Warn' -Message 'Directory exists but no .md files'
    }
} else {
    Add-TestResult -Category 'KnowledgeBase' -TestName 'Netapp Cases' -Status 'Warn' -Message 'Directory not found (gitignored — normal for clean clone)'
}

# KnownIssues
$kiDir = Join-Path $rootDir 'KnownIssues'
if (Test-Path $kiDir) {
    $kiFiles = Get-ChildItem $kiDir -File -Filter '*.md' -ErrorAction SilentlyContinue
    $kiEmpty = $kiFiles | Where-Object { $_.Length -eq 0 }
    $msg = "$($kiFiles.Count) article(s)"
    if ($kiEmpty.Count -gt 0) { $msg += " ($($kiEmpty.Count) empty!)" }
    Add-TestResult -Category 'KnowledgeBase' -TestName 'KnownIssues' -Status $(if ($kiEmpty.Count) { 'Warn' } else { 'Pass' }) -Message $msg
} else {
    Add-TestResult -Category 'KnowledgeBase' -TestName 'KnownIssues' -Status 'Warn' -Message 'Directory not found'
}

# PDFs
$pdfDir = Join-Path $rootDir 'PDF'
if (Test-Path $pdfDir) {
    $pdfFiles = Get-ChildItem $pdfDir -File -Filter '*.pdf' -ErrorAction SilentlyContinue
    if ($pdfFiles.Count -gt 0) {
        Add-TestResult -Category 'KnowledgeBase' -TestName 'PDF Library' -Status 'Pass' -Message "$($pdfFiles.Count) PDF(s)"
    } else {
        Add-TestResult -Category 'KnowledgeBase' -TestName 'PDF Library' -Status 'Warn' -Message 'Directory exists but no PDFs'
    }
} else {
    Add-TestResult -Category 'KnowledgeBase' -TestName 'PDF Library' -Status 'Warn' -Message 'PDF directory not found'
}

# ============================================================
# PHASE 8: Network & Cluster Connectivity
# ============================================================
if ($SkipConnectivity) {
    Write-Host "`n── Phase 8: Connectivity (SKIPPED) ─────────────────────────────" -ForegroundColor DarkGray
    Add-TestResult -Category 'Connectivity' -TestName 'All tests' -Status 'Skip' -Message 'Skipped by -SkipConnectivity'
} elseif (-not $configLoaded) {
    Write-Host "`n── Phase 8: Connectivity (SKIPPED — no config) ─────────────────" -ForegroundColor DarkGray
    Add-TestResult -Category 'Connectivity' -TestName 'All tests' -Status 'Skip' -Message 'Config not loaded — cannot run connectivity tests'
} else {
    Write-Host "`n── Phase 8: Network Reachability ───────────────────────────────" -ForegroundColor White

    foreach ($cl in $global:ONTAP_Clusters) {
        $host_ = if ($cl.FallbackIP) { $cl.FallbackIP } else { $cl.ConnectName }
        $label = "$($cl.ClusterName) ($host_)"

        # DNS resolution (skip for IPs)
        if ($host_ -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
            try {
                $dns = [System.Net.Dns]::GetHostAddresses($host_)
                Add-TestResult -Category 'Network' -TestName "DNS: $($cl.ClusterName)" -Status 'Pass' -Message "$host_ -> $($dns[0])"
            } catch {
                Add-TestResult -Category 'Network' -TestName "DNS: $($cl.ClusterName)" -Status 'Fail' -Message "Cannot resolve $host_"
            }
        } else {
            Add-TestResult -Category 'Network' -TestName "DNS: $($cl.ClusterName)" -Status 'Pass' -Message "IP address (no DNS needed): $host_"
        }

        # TCP 22 (SSH)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $tcp22 = Test-NetConnection -ComputerName $host_ -Port 22 -WarningAction SilentlyContinue -InformationLevel Quiet
        $sw.Stop()
        if ($tcp22) {
            Add-TestResult -Category 'Network' -TestName "TCP/22: $($cl.ClusterName)" -Status 'Pass' -Message "${sw.ElapsedMilliseconds}ms" -DurationMs $sw.ElapsedMilliseconds
        } else {
            Add-TestResult -Category 'Network' -TestName "TCP/22: $($cl.ClusterName)" -Status 'Fail' -Message 'Port 22 unreachable' -DurationMs $sw.ElapsedMilliseconds
        }

        # TCP 443 (HTTPS/REST)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $tcp443 = Test-NetConnection -ComputerName $host_ -Port 443 -WarningAction SilentlyContinue -InformationLevel Quiet
        $sw.Stop()
        if ($tcp443) {
            Add-TestResult -Category 'Network' -TestName "TCP/443: $($cl.ClusterName)" -Status 'Pass' -Message "${sw.ElapsedMilliseconds}ms" -DurationMs $sw.ElapsedMilliseconds
        } else {
            Add-TestResult -Category 'Network' -TestName "TCP/443: $($cl.ClusterName)" -Status 'Warn' -Message 'Port 443 unreachable (REST API unavailable)' -DurationMs $sw.ElapsedMilliseconds
        }
    }

    # SSH Connectivity
    Write-Host "`n── Phase 8b: SSH Connectivity ──────────────────────────────────" -ForegroundColor White

    foreach ($cl in $global:ONTAP_Clusters) {
        $host_ = if ($cl.FallbackIP) { $cl.FallbackIP } else { $cl.ConnectName }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $sshOut, $ec = Invoke-ClusterSsh -Host_ $host_ -Cmd 'version' -TimeoutSec 15
            $sw.Stop()
            if ($ec -eq 0) {
                $ver = [string]($sshOut | Select-Object -First 1)
                Add-TestResult -Category 'SSH' -TestName $cl.ClusterName -Status 'Pass' -Message $ver.Trim() -DurationMs $sw.ElapsedMilliseconds
            } elseif ($ec -eq 124) {
                Add-TestResult -Category 'SSH' -TestName $cl.ClusterName -Status 'Fail' -Message "SSH timed out after 15s" -DurationMs $sw.ElapsedMilliseconds
            } else {
                $errLine = [string]($sshOut | Select-Object -First 1) -replace "`r|`n", ''
                Add-TestResult -Category 'SSH' -TestName $cl.ClusterName -Status 'Fail' -Message "Exit $ec : $errLine" -DurationMs $sw.ElapsedMilliseconds
            }
        } catch {
            $sw.Stop()
            Add-TestResult -Category 'SSH' -TestName $cl.ClusterName -Status 'Fail' -Message $_.Exception.Message -DurationMs $sw.ElapsedMilliseconds
        }
    }

    # ZAPI Connectivity (requires NetApp.ONTAP + credential)
    Write-Host "`n── Phase 8c: ZAPI Connectivity ─────────────────────────────────" -ForegroundColor White

    $zapiCred = $null
    $zapiUser = $global:ONTAP_ROUser
    if ($zapiUser) {
        $credFile = Join-Path $rootDir "credentials\$zapiUser.cred"
        if (Test-Path $credFile) {
            try {
                $secPass = & "$rootDir\scripts\credentials\Get-Credential.ps1" -Name $zapiUser -AsSecureString
                $zapiCred = New-Object System.Management.Automation.PSCredential($zapiUser, $secPass)
                Add-TestResult -Category 'ZAPI' -TestName 'RO Credential' -Status 'Pass' -Message "Loaded $zapiUser.cred"
            } catch {
                Add-TestResult -Category 'ZAPI' -TestName 'RO Credential' -Status 'Fail' -Message $_.Exception.Message
            }
        } else {
            Add-TestResult -Category 'ZAPI' -TestName 'RO Credential' -Status 'Warn' -Message "No $zapiUser.cred — ZAPI tests skipped"
        }
    } else {
        Add-TestResult -Category 'ZAPI' -TestName 'RO Credential' -Status 'Skip' -Message 'ONTAP_ROUser not configured'
    }

    if ($zapiCred -and $mod) {
        foreach ($cl in $global:ONTAP_Clusters) {
            $addr = if ($cl.FallbackIP) { $cl.FallbackIP } else { $cl.ConnectName }
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $conn = Connect-NcController $addr -Credential $zapiCred -ErrorAction Stop
                $sw.Stop()
                Add-TestResult -Category 'ZAPI' -TestName $cl.ClusterName -Status 'Pass' -Message "v$($conn.Version) — $($conn.Name)" -DurationMs $sw.ElapsedMilliseconds
            } catch {
                $sw.Stop()
                Add-TestResult -Category 'ZAPI' -TestName $cl.ClusterName -Status 'Fail' -Message $_.Exception.Message -DurationMs $sw.ElapsedMilliseconds
            }
        }
    } elseif (-not $mod) {
        Add-TestResult -Category 'ZAPI' -TestName 'All clusters' -Status 'Skip' -Message 'NetApp.ONTAP module not available'
    }
}

# ============================================================
# PHASE 9: Script Dependency Chains
# ============================================================
Write-Host "`n── Phase 9: Script Dependency Chains ───────────────────────────" -ForegroundColor White

# Validate that scripts in scripts/<sub>/ correctly resolve to workspace root
$depScripts = @(
    @{ Name = 'sas-diag.ps1';         Dir = "$rootDir\scripts\disk" }
    @{ Name = 'Get-BiggestSnapshot.ps1'; Dir = "$rootDir\scripts\snapshots" }
    @{ Name = 'Get-DR-Report.ps1';     Dir = "$rootDir\scripts\reports" }
    @{ Name = 'Monitor-SnapMirror.ps1'; Dir = "$rootDir\scripts\snapmirror" }
    @{ Name = 'Ndmp_Copy.ps1';         Dir = "$rootDir\scripts\ndmp-copy" }
    @{ Name = 'Clusters Quota Policy Manger.ps1'; Dir = "$rootDir\scripts\quota" }
    @{ Name = 'Test-NetappROUser.ps1';  Dir = "$rootDir\scripts\testing" }
    @{ Name = 'Test-VserverConfigOverrideAPI.ps1'; Dir = "$rootDir\scripts\testing" }
)

foreach ($dep in $depScripts) {
    $scriptDir = $dep.Dir
    $expectedRoot = $rootDir
    # Scripts in scripts/<sub>/ use: (Resolve-Path "$PSScriptRoot\..\..").Path
    try {
        $resolved = (Resolve-Path (Join-Path $scriptDir '..\..') -ErrorAction Stop).Path
        if ($resolved -eq $expectedRoot) {
            Add-TestResult -Category 'Dependencies' -TestName "$($dep.Name) root resolution" -Status 'Pass' -Message "Resolves to $resolved"
        } else {
            Add-TestResult -Category 'Dependencies' -TestName "$($dep.Name) root resolution" -Status 'Fail' -Message "Expected $expectedRoot, got $resolved"
        }
    } catch {
        Add-TestResult -Category 'Dependencies' -TestName "$($dep.Name) root resolution" -Status 'Fail' -Message $_.Exception.Message
    }
}

# Ansible scripts use $PSScriptRoot directly for some deps
$ansibleDir = "$rootDir\ansible\s3-bucket-provision"
if (Test-Path $ansibleDir) {
    $ymlFiles = Get-ChildItem $ansibleDir -Filter '*.yml' -ErrorAction SilentlyContinue
    Add-TestResult -Category 'Dependencies' -TestName 'Ansible playbooks' -Status 'Pass' -Message "$($ymlFiles.Count) YAML file(s) in s3-bucket-provision"
} else {
    Add-TestResult -Category 'Dependencies' -TestName 'Ansible playbooks' -Status 'Warn' -Message 'Ansible directory not found'
}

# ============================================================
# PHASE 10: S3 Configuration
# ============================================================
Write-Host "`n── Phase 10: S3 Configuration ──────────────────────────────────" -ForegroundColor White

if ($configLoaded -and $global:Config.S3_Config) {
    Add-TestResult -Category 'S3' -TestName 'S3_Config section' -Status 'Pass' -Message 'Present in config.json'

    if ($global:Config.S3_Config.Clusters) {
        $s3Clusters = @($global:Config.S3_Config.Clusters.PSObject.Properties)
        $s3Count = $s3Clusters.Count
        Add-TestResult -Category 'S3' -TestName 'S3 cluster count' -Status 'Pass' -Message "$s3Count cluster(s) configured"

        foreach ($s3cl in $s3Clusters) {
            $s3Name = $s3cl.Name
            $s3Val  = $s3cl.Value
            $s3Missing = @()
            if (-not $s3Val.Vserver)        { $s3Missing += 'Vserver' }
            if (-not $s3Val.S3User)         { $s3Missing += 'S3User' }
            if (-not $s3Val.OntapUsername)   { $s3Missing += 'OntapUsername' }
            if (-not $s3Val.CredentialName)  { $s3Missing += 'CredentialName' }

            if ($s3Missing.Count -gt 0) {
                Add-TestResult -Category 'S3' -TestName "S3: $s3Name" -Status 'Warn' -Message "Missing fields: $($s3Missing -join ', ')"
            } else {
                Add-TestResult -Category 'S3' -TestName "S3: $s3Name" -Status 'Pass' -Message "SVM=$($s3Val.Vserver) User=$($s3Val.S3User)"
            }

            # Check S3 credential file exists
            if ($s3Val.CredentialName) {
                $s3CredFile = Join-Path $rootDir "credentials\$($s3Val.CredentialName).cred"
                if (Test-Path $s3CredFile) {
                    Add-TestResult -Category 'S3' -TestName "S3 cred: $($s3Val.CredentialName)" -Status 'Pass' -Message 'Credential file exists'
                } else {
                    Add-TestResult -Category 'S3' -TestName "S3 cred: $($s3Val.CredentialName)" -Status 'Warn' -Message "File not found: $s3CredFile"
                }
            }

            # Check vault file if specified
            if ($s3Val.VaultFile) {
                $vaultPath = Join-Path $rootDir 'credentials' $s3Val.VaultFile
                if (Test-Path $vaultPath) {
                    Add-TestResult -Category 'S3' -TestName "S3 vault: $s3Name" -Status 'Pass' -Message (Split-Path $s3Val.VaultFile -Leaf)
                } else {
                    Add-TestResult -Category 'S3' -TestName "S3 vault: $s3Name" -Status 'Warn' -Message "Vault file not found: $($s3Val.VaultFile)"
                }
            }
        }
    } else {
        Add-TestResult -Category 'S3' -TestName 'S3 clusters' -Status 'Warn' -Message 'S3_Config.Clusters section is empty'
    }
} else {
    Add-TestResult -Category 'S3' -TestName 'S3_Config section' -Status 'Warn' -Message 'Not found in config.json (S3 provisioning unavailable)'
}

# ============================================================
# PHASE 11: Ansible & Vault Files
# ============================================================
Write-Host "`n── Phase 11: Ansible & Vault Files ─────────────────────────────" -ForegroundColor White

$ansibleS3Dir = "$rootDir\ansible\s3-bucket-provision"
if (Test-Path $ansibleS3Dir) {
    # Check each expected playbook
    $expectedPlaybooks = @(
        'provision_s3_bucket.yml'
        'provision_s3_bucket_admin.yml'
        'provision_s3_bucket_dev.yml'
        'provision_s3_bucket_generic.yml'
    )
    foreach ($pb in $expectedPlaybooks) {
        $pbPath = Join-Path $ansibleS3Dir $pb
        if (Test-Path $pbPath) {
            Add-TestResult -Category 'Ansible' -TestName "Playbook: $pb" -Status 'Pass' -Message "$('{0:N0}' -f (Get-Item $pbPath).Length) bytes"
        } else {
            Add-TestResult -Category 'Ansible' -TestName "Playbook: $pb" -Status 'Warn' -Message 'File not found'
        }
    }

    # Check vault credential files in root credentials/ folder
    $vaultDir = Join-Path $rootDir 'credentials'
    if (Test-Path $vaultDir) {
        $vaultFiles = Get-ChildItem $vaultDir -Filter 'vault_credentials*.yml' -ErrorAction SilentlyContinue
        if ($vaultFiles.Count -gt 0) {
            Add-TestResult -Category 'Ansible' -TestName 'Vault files' -Status 'Pass' -Message "$($vaultFiles.Count) file(s): $($vaultFiles.Name -join ', ')"
        } else {
            Add-TestResult -Category 'Ansible' -TestName 'Vault files' -Status 'Warn' -Message 'No vault_credentials*.yml files in credentials/'
        }
    } else {
        Add-TestResult -Category 'Ansible' -TestName 'Vault directory' -Status 'Warn' -Message 'credentials/ directory not found'
    }

    # Ansible syntax check via WSL (if available)
    if (Get-Command 'wsl' -ErrorAction SilentlyContinue) {
        $wslPath = ($ansibleS3Dir -replace '\\','/' -replace '^([A-Za-z]):',{ '/mnt/' + $_.Groups[1].Value.ToLower() })
        foreach ($pb in @('provision_s3_bucket_generic.yml')) {
            $pbFull = Join-Path $ansibleS3Dir $pb
            if (Test-Path $pbFull) {
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                $syntaxOut = wsl -d Ubuntu-22.04 -- bash --norc --noprofile -c "export PATH=/usr/local/bin:/usr/bin:/bin:`$HOME/.local/bin; cd '$wslPath'; ansible-playbook --syntax-check $pb" 2>&1
                $sw.Stop()
                if ($LASTEXITCODE -eq 0) {
                    Add-TestResult -Category 'Ansible' -TestName "Syntax: $pb" -Status 'Pass' -Message 'Playbook syntax OK' -DurationMs $sw.ElapsedMilliseconds
                } elseif ($syntaxOut -match 'command not found|not found') {
                    Add-TestResult -Category 'Ansible' -TestName "Syntax: $pb" -Status 'Warn' -Message 'ansible-playbook not installed in WSL' -DurationMs $sw.ElapsedMilliseconds
                } else {
                    $errMsg = ($syntaxOut | Select-Object -First 2) -join ' '
                    Add-TestResult -Category 'Ansible' -TestName "Syntax: $pb" -Status 'Fail' -Message $errMsg -DurationMs $sw.ElapsedMilliseconds
                }
            }
        }

        # Check netapp.ontap Ansible collection
        $collOut = wsl -d Ubuntu-22.04 -- bash --norc --noprofile -c 'export PATH=/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin; ansible-galaxy collection list netapp.ontap' 2>&1
        if ($collOut -match 'netapp\.ontap\s+([\d.]+)') {
            Add-TestResult -Category 'Ansible' -TestName 'netapp.ontap collection' -Status 'Pass' -Message "v$($Matches[1])"
        } else {
            Add-TestResult -Category 'Ansible' -TestName 'netapp.ontap collection' -Status 'Warn' -Message 'Not installed in WSL'
        }

        # S3 Ansible dry-run (--check) against config-driven S3_Config clusters
        if ($configLoaded -and $global:Config.S3_Config -and $global:Config.S3_Config.Clusters) {
            $credScript = Join-Path $rootDir 'scripts\credentials\Get-Credential.ps1'
            foreach ($s3Prop in $global:Config.S3_Config.Clusters.PSObject.Properties) {
                $s3Name = $s3Prop.Name
                $s3Cfg  = $s3Prop.Value
                # Resolve admin credential — use API_Cred for admin access
                $clObj = $global:ONTAP_Clusters | Where-Object { $_.ClusterName -eq $s3Name } | Select-Object -First 1
                $credName = if ($clObj -and $clObj.API_Cred) { $clObj.API_Cred } else { $s3Cfg.CredentialName }
                $credFile = Join-Path $rootDir "credentials\$credName.cred"
                if (-not (Test-Path $credFile)) {
                    Add-TestResult -Category 'Ansible' -TestName "S3-DryRun: $s3Name" -Status 'Skip' -Message "Credential file missing: $credName.cred"
                    continue
                }
                $ontapPw = try { & $credScript -Name $credName } catch { '' }
                if (-not $ontapPw) {
                    Add-TestResult -Category 'Ansible' -TestName "S3-DryRun: $s3Name" -Status 'Skip' -Message "Cannot decrypt $credName.cred"
                    continue
                }
                $hostname = if ($clObj -and $clObj.FallbackIP) { $clObj.FallbackIP } else { $s3Name }
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                $dryOut = wsl -d Ubuntu-22.04 -- bash --norc --noprofile -c "export PATH=/usr/local/bin:/usr/bin:/bin:`$HOME/.local/bin; cd '$wslPath'; ansible-playbook provision_s3_bucket_generic.yml --check -e 'ontap_hostname=$hostname ontap_vserver=$($s3Cfg.Vserver) ontap_username=admin ontap_password=$ontapPw bucket_name=test-health-check-dryrun s3_user=$($s3Cfg.S3User)'" 2>&1
                $sw.Stop()
                if ($LASTEXITCODE -eq 0) {
                    Add-TestResult -Category 'Ansible' -TestName "S3-DryRun: $s3Name" -Status 'Pass' -Message "Dry-run OK ($($s3Cfg.Vserver))" -DurationMs $sw.ElapsedMilliseconds
                } else {
                    $errLine = ($dryOut | Where-Object { $_ -match 'FAILED|fatal|ERROR' } | Select-Object -First 1) -replace '\s+', ' '
                    if (-not $errLine) { $errLine = ($dryOut | Select-Object -Last 3) -join ' ' }
                    Add-TestResult -Category 'Ansible' -TestName "S3-DryRun: $s3Name" -Status 'Fail' -Message "$($s3Cfg.Vserver): $errLine" -DurationMs $sw.ElapsedMilliseconds
                }
            }
        }
    } else {
        Add-TestResult -Category 'Ansible' -TestName 'Ansible validation' -Status 'Skip' -Message 'WSL not available'
    }
} else {
    Add-TestResult -Category 'Ansible' -TestName 'Ansible S3 directory' -Status 'Warn' -Message 'ansible/s3-bucket-provision/ not found'
}

# ============================================================
# PHASE 12: AWS CLI & S3 Client Tools
# ============================================================
Write-Host "`n── Phase 12: AWS CLI & S3 Client Tools ─────────────────────────" -ForegroundColor White

# AWS CLI
$awsCmd = Get-Command 'aws' -ErrorAction SilentlyContinue
if ($awsCmd) {
    $awsVer = try { (aws --version 2>&1) -replace "`r|`n",'' } catch { '' }
    Add-TestResult -Category 'S3-Tools' -TestName 'AWS CLI' -Status 'Pass' -Message $awsVer
} else {
    Add-TestResult -Category 'S3-Tools' -TestName 'AWS CLI' -Status 'Warn' -Message 'Not installed (optional — used for S3 bucket operations)'
}

# rclone
$rcloneCmd = Get-Command 'rclone' -ErrorAction SilentlyContinue
if ($rcloneCmd) {
    $rcloneVer = try { (rclone version 2>&1 | Select-Object -First 1) } catch { '' }
    Add-TestResult -Category 'S3-Tools' -TestName 'rclone' -Status 'Pass' -Message $rcloneVer
} else {
    Add-TestResult -Category 'S3-Tools' -TestName 'rclone' -Status 'Warn' -Message 'Not installed (optional — used for S3 sync/copy)'
}

# ============================================================
# PHASE 13: DFS Configuration
# ============================================================
Write-Host "`n── Phase 13: DFS Configuration ─────────────────────────────────" -ForegroundColor White

if ($configLoaded -and $global:Config.DFS_Config) {
    $dfsEntries = $global:Config.DFS_Config.PSObject.Properties
    Add-TestResult -Category 'DFS' -TestName 'DFS_Config section' -Status 'Pass' -Message "$($dfsEntries.Count) cluster(s) configured"

    foreach ($dfs in $dfsEntries) {
        $dfsName = $dfs.Name
        $dfsVal  = $dfs.Value
        $dfsMissing = @()
        if (-not $dfsVal.Vserver)    { $dfsMissing += 'Vserver' }
        if (-not $dfsVal.CifsServer) { $dfsMissing += 'CifsServer' }
        if (-not $dfsVal.DfsShare)   { $dfsMissing += 'DfsShare' }
        if (-not $dfsVal.DfsPath)    { $dfsMissing += 'DfsPath' }
        if (-not $dfsVal.Domain)     { $dfsMissing += 'Domain' }

        if ($dfsMissing.Count -gt 0) {
            Add-TestResult -Category 'DFS' -TestName "DFS: $dfsName" -Status 'Warn' -Message "Missing: $($dfsMissing -join ', ')"
        } else {
            Add-TestResult -Category 'DFS' -TestName "DFS: $dfsName" -Status 'Pass' -Message "SVM=$($dfsVal.Vserver) CIFS=$($dfsVal.CifsServer) Share=$($dfsVal.DfsShare) Domain=$($dfsVal.Domain)"
        }
    }

    # Check DFS module loaded (from Personal_modules)
    if (Get-Command 'Find-DFSPath' -ErrorAction SilentlyContinue) {
        Add-TestResult -Category 'DFS' -TestName 'Find-DFSPath function' -Status 'Pass' -Message 'Available'
    } elseif (Get-Command 'Get-DFSNameSpaceRoot' -ErrorAction SilentlyContinue) {
        Add-TestResult -Category 'DFS' -TestName 'Get-DFSNameSpaceRoot function' -Status 'Pass' -Message 'Available'
    } else {
        Add-TestResult -Category 'DFS' -TestName 'DFS functions' -Status 'Warn' -Message 'Find-DFSPath / Get-DFSNameSpaceRoot not loaded'
    }
} else {
    Add-TestResult -Category 'DFS' -TestName 'DFS_Config section' -Status 'Warn' -Message 'Not found in config.json'
}

# ============================================================
# PHASE 14: NDMP Configuration
# ============================================================
Write-Host "`n── Phase 14: NDMP Configuration ────────────────────────────────" -ForegroundColor White

if ($configLoaded -and $global:Config.NDMP_Config) {
    $ndmp = $global:Config.NDMP_Config
    Add-TestResult -Category 'NDMP' -TestName 'NDMP_Config section' -Status 'Pass' -Message 'Present in config.json'

    # Required fields
    $ndmpMissing = @()
    if (-not $ndmp.BackupUser)       { $ndmpMissing += 'BackupUser' }
    if (-not $ndmp.CredentialPrefix) { $ndmpMissing += 'CredentialPrefix' }
    if (-not $ndmp.SrcCluster)       { $ndmpMissing += 'SrcCluster' }
    if (-not $ndmp.DstCluster)       { $ndmpMissing += 'DstCluster' }
    if (-not $ndmp.SRC)              { $ndmpMissing += 'SRC' }
    if (-not $ndmp.DST)              { $ndmpMissing += 'DST' }

    if ($ndmpMissing.Count -gt 0) {
        Add-TestResult -Category 'NDMP' -TestName 'NDMP fields' -Status 'Warn' -Message "Missing: $($ndmpMissing -join ', ')"
    } else {
        Add-TestResult -Category 'NDMP' -TestName 'NDMP fields' -Status 'Pass' -Message "Src=$($ndmp.SrcCluster) Dst=$($ndmp.DstCluster) User=$($ndmp.BackupUser)"
    }

    # Check NdmpPassword field exists on each cluster
    foreach ($cl in $global:Config.ONTAP_Clusters) {
        if ($cl.NdmpPassword) {
            Add-TestResult -Category 'NDMP' -TestName "NdmpPassword: $($cl.ClusterName)" -Status 'Pass' -Message 'Set (value not logged)'
        } else {
            Add-TestResult -Category 'NDMP' -TestName "NdmpPassword: $($cl.ClusterName)" -Status 'Warn' -Message 'Not set — ndmpcopy to/from this cluster will fail'
        }
    }
} else {
    Add-TestResult -Category 'NDMP' -TestName 'NDMP_Config section' -Status 'Warn' -Message 'Not found in config.json'
}

# ============================================================
# PHASE 15: Git Repository Health
# ============================================================
Write-Host "`n── Phase 15: Git Repository ────────────────────────────────────" -ForegroundColor White

$gitDir = Join-Path $rootDir '.git'
if (Test-Path $gitDir) {
    Add-TestResult -Category 'Git' -TestName '.git directory' -Status 'Pass' -Message 'Repository initialized'

    # Current branch
    $branch = git -C $rootDir branch --show-current 2>$null
    if ($branch) {
        Add-TestResult -Category 'Git' -TestName 'Current branch' -Status 'Pass' -Message $branch
    } else {
        Add-TestResult -Category 'Git' -TestName 'Current branch' -Status 'Warn' -Message 'Detached HEAD or error'
    }

    # Check expected branches
    foreach ($expectedBranch in @('master', 'public-clean')) {
        $refCheck = git -C $rootDir show-ref --verify "refs/heads/$expectedBranch" 2>$null
        if ($LASTEXITCODE -eq 0) {
            Add-TestResult -Category 'Git' -TestName "Branch: $expectedBranch" -Status 'Pass' -Message 'Exists'
        } else {
            Add-TestResult -Category 'Git' -TestName "Branch: $expectedBranch" -Status 'Warn' -Message 'Not found locally'
        }
    }

    # Remotes
    $remotes = git -C $rootDir remote -v 2>$null
    if ($remotes) {
        $remoteNames = ($remotes | ForEach-Object { ($_ -split '\t')[0] } | Sort-Object -Unique) -join ', '
        Add-TestResult -Category 'Git' -TestName 'Remotes' -Status 'Pass' -Message $remoteNames
    } else {
        Add-TestResult -Category 'Git' -TestName 'Remotes' -Status 'Warn' -Message 'No remotes configured'
    }

    # Dirty working tree check
    $gitStatus = git -C $rootDir status --porcelain 2>$null
    $dirtyCount = ($gitStatus | Measure-Object).Count
    if ($dirtyCount -eq 0) {
        Add-TestResult -Category 'Git' -TestName 'Working tree' -Status 'Pass' -Message 'Clean'
    } else {
        Add-TestResult -Category 'Git' -TestName 'Working tree' -Status 'Warn' -Message "$dirtyCount uncommitted change(s)"
    }
} else {
    Add-TestResult -Category 'Git' -TestName '.git directory' -Status 'Fail' -Message 'Not a git repository'
}

# ============================================================
# PHASE 16: Docs Hub
# ============================================================
Write-Host "`n── Phase 16: Docs Hub ──────────────────────────────────────────" -ForegroundColor White

# Docs_Port from config
if ($configLoaded -and $global:Config.Docs_Port) {
    $docsPort = $global:Config.Docs_Port
    if ($docsPort -is [int] -or $docsPort -match '^\d+$') {
        $portNum = [int]$docsPort
        if ($portNum -gt 0 -and $portNum -lt 65536) {
            Add-TestResult -Category 'Docs' -TestName 'Docs_Port' -Status 'Pass' -Message "Port $portNum"
        } else {
            Add-TestResult -Category 'Docs' -TestName 'Docs_Port' -Status 'Fail' -Message "Invalid port: $portNum"
        }
    } else {
        Add-TestResult -Category 'Docs' -TestName 'Docs_Port' -Status 'Fail' -Message "Not a number: $docsPort"
    }
} else {
    Add-TestResult -Category 'Docs' -TestName 'Docs_Port' -Status 'Warn' -Message 'Not set in config.json'
}

# docs/index.html
$docsIndex = Join-Path $rootDir 'docs\index.html'
if (Test-Path $docsIndex) {
    $indexSize = (Get-Item $docsIndex).Length
    Add-TestResult -Category 'Docs' -TestName 'docs/index.html' -Status 'Pass' -Message "$('{0:N0}' -f $indexSize) bytes"
} else {
    Add-TestResult -Category 'Docs' -TestName 'docs/index.html' -Status 'Warn' -Message 'Not found'
}

# ============================================================
# PHASE 17: CSV CLI Smoke Test (via SSH)
# ============================================================
if (-not $SkipConnectivity -and $configLoaded) {
    Write-Host "`n── Phase 17: CSV CLI Smoke Test ────────────────────────────────" -ForegroundColor White

    # Pick first reachable cluster and test Invoke-OntapCsv end-to-end
    $csvTestCluster = $global:ONTAP_Clusters | Select-Object -First 1
    if ($csvTestCluster) {
        $csvSshFn = "$($csvTestCluster.ConnectName)-s"
        $csvFn    = "Get-$($csvTestCluster.CsvPrefix)Csv"

        if (Get-Command $csvFn -ErrorAction SilentlyContinue) {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $csvResult = & $csvFn -Command 'vserver show -fields vserver,type,state' 2>&1
                $sw.Stop()
                if ($csvResult -and $csvResult.Count -gt 0 -and $csvResult[0].PSObject.Properties.Name -contains 'vserver') {
                    Add-TestResult -Category 'CSV-CLI' -TestName "$csvFn smoke test" -Status 'Pass' -Message "$($csvResult.Count) SVM(s) returned" -DurationMs $sw.ElapsedMilliseconds
                } else {
                    Add-TestResult -Category 'CSV-CLI' -TestName "$csvFn smoke test" -Status 'Warn' -Message 'Command returned data but format unexpected' -DurationMs $sw.ElapsedMilliseconds
                }
            } catch {
                $sw.Stop()
                Add-TestResult -Category 'CSV-CLI' -TestName "$csvFn smoke test" -Status 'Fail' -Message $_.Exception.Message -DurationMs $sw.ElapsedMilliseconds
            }
        } else {
            Add-TestResult -Category 'CSV-CLI' -TestName "$csvFn smoke test" -Status 'Skip' -Message "Function $csvFn not found"
        }
    }
} elseif ($SkipConnectivity) {
    Add-TestResult -Category 'CSV-CLI' -TestName 'CSV CLI smoke test' -Status 'Skip' -Message 'Skipped by -SkipConnectivity'
}

# ============================================================
# PHASE 18: REST API Smoke Test
# ============================================================
if (-not $SkipConnectivity -and $configLoaded) {
    Write-Host "`n── Phase 18: REST API Smoke Test ───────────────────────────────" -ForegroundColor White

    # Test /api/cluster on each cluster that has API_Cred defined
    $restClusters = $global:ONTAP_Clusters | Where-Object { $_.API_Cred }
    if (-not $restClusters) {
        Add-TestResult -Category 'REST-API' -TestName 'REST API smoke test' -Status 'Skip' -Message 'No clusters have API_Cred in config.json'
    }
    foreach ($restCl in $restClusters) {
        $restHost = if ($restCl.FallbackIP) { $restCl.FallbackIP } else { $restCl.ConnectName }
        $getCredScript = Join-Path $rootDir 'scripts\credentials\Get-Credential.ps1'

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $secPass = & $getCredScript -Name $restCl.API_Cred -AsSecureString
            $apiCred = [pscredential]::new('admin', $secPass)

            $restResp = Invoke-RestMethod -Uri "https://$restHost/api/cluster" -Method GET -Credential $apiCred -SkipCertificateCheck -ErrorAction Stop -TimeoutSec 15
            $sw.Stop()
            Add-TestResult -Category 'REST-API' -TestName "/api/cluster ($($restCl.ClusterName))" -Status 'Pass' -Message "ONTAP $($restResp.version.full) — $($restResp.name)" -DurationMs $sw.ElapsedMilliseconds
        } catch {
            $sw.Stop()
            $restErr = $_.Exception.Message -replace "`r|`n",' '
            if ($restErr -match '401|403|Unauthorized') {
                Add-TestResult -Category 'REST-API' -TestName "/api/cluster ($($restCl.ClusterName))" -Status 'Warn' -Message "Endpoint reachable but auth failed" -DurationMs $sw.ElapsedMilliseconds
            } elseif ($restErr -match 'Credential file not found') {
                Add-TestResult -Category 'REST-API' -TestName "/api/cluster ($($restCl.ClusterName))" -Status 'Warn' -Message "Missing cred file: $($restCl.API_Cred).cred" -DurationMs $sw.ElapsedMilliseconds
            } else {
                Add-TestResult -Category 'REST-API' -TestName "/api/cluster ($($restCl.ClusterName))" -Status 'Fail' -Message $restErr -DurationMs $sw.ElapsedMilliseconds
            }
        }
    }
} elseif ($SkipConnectivity) {
    Add-TestResult -Category 'REST-API' -TestName 'REST API smoke test' -Status 'Skip' -Message 'Skipped by -SkipConnectivity'
}

# ============================================================
# PHASE 19: Config Template Drift
# ============================================================
Write-Host "`n── Phase 19: Config Template Drift ────────────────────────────" -ForegroundColor White

$configJsonPath     = Join-Path $rootDir 'config.json'
$configTemplatePath = Join-Path $rootDir 'config.template.json'

if (-not (Test-Path $configTemplatePath)) {
    Add-TestResult -Category 'TemplateDrift' -TestName 'config.template.json' -Status 'Fail' -Message 'Template file not found'
} elseif (-not (Test-Path $configJsonPath)) {
    Add-TestResult -Category 'TemplateDrift' -TestName 'config.json' -Status 'Fail' -Message 'config.json not found'
} else {
    try {
        $template   = Get-Content $configTemplatePath -Raw | ConvertFrom-Json
        $actual     = Get-Content $configJsonPath     -Raw | ConvertFrom-Json

        $templateKeys = $template.PSObject.Properties.Name | Sort-Object
        $actualKeys   = $actual.PSObject.Properties.Name   | Sort-Object

        $missingFromActual = $templateKeys | Where-Object { $_ -notin $actualKeys }
        $extraInActual     = $actualKeys   | Where-Object { $_ -notin $templateKeys }

        if ($missingFromActual.Count -eq 0 -and $extraInActual.Count -eq 0) {
            Add-TestResult -Category 'TemplateDrift' -TestName 'Top-level keys' -Status 'Pass' -Message "$($actualKeys.Count) key(s) match template"
        } else {
            if ($missingFromActual.Count -gt 0) {
                Add-TestResult -Category 'TemplateDrift' -TestName 'Missing keys' -Status 'Warn' `
                    -Message "In template but not in config.json: $($missingFromActual -join ', ')"
            }
            if ($extraInActual.Count -gt 0) {
                Add-TestResult -Category 'TemplateDrift' -TestName 'Extra keys' -Status 'Warn' `
                    -Message "In config.json but not in template: $($extraInActual -join ', ')"
            }
        }

        # Check each cluster entry has the same keys as the first template cluster
        if ($template.ONTAP_Clusters -and $actual.ONTAP_Clusters) {
            $templateClusterKeys = $template.ONTAP_Clusters[0].PSObject.Properties.Name | Sort-Object
            foreach ($cl in $actual.ONTAP_Clusters) {
                $clKeys    = $cl.PSObject.Properties.Name | Sort-Object
                $clMissing = $templateClusterKeys | Where-Object { $_ -notin $clKeys }
                if ($clMissing.Count -gt 0) {
                    Add-TestResult -Category 'TemplateDrift' -TestName "Cluster $($cl.ClusterName ?? $cl.ConnectName)" `
                        -Status 'Warn' -Message "Missing fields vs template: $($clMissing -join ', ')"
                } else {
                    Add-TestResult -Category 'TemplateDrift' -TestName "Cluster $($cl.ClusterName ?? $cl.ConnectName)" `
                        -Status 'Pass' -Message 'All cluster fields present'
                }
            }
        }
    } catch {
        Add-TestResult -Category 'TemplateDrift' -TestName 'Parse' -Status 'Fail' -Message $_.Exception.Message
    }
}

# ============================================================
# PHASE 20: Session Log Recency
# ============================================================
Write-Host "`n── Phase 20: Session Log Recency ──────────────────────────────" -ForegroundColor White

$sessionLogDir = Join-Path $rootDir '.github'
$sessionLogs   = Get-ChildItem $sessionLogDir -Filter 'session-log-*.md' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending

if ($sessionLogs.Count -eq 0) {
    Add-TestResult -Category 'SessionLog' -TestName 'Session logs' -Status 'Warn' -Message 'No session-log-*.md files found in .github/'
} else {
    $latest    = $sessionLogs[0]
    $ageInDays = ((Get-Date) - $latest.LastWriteTime).TotalDays
    $ageStr    = "$([math]::Round($ageInDays, 0)) days ago ($($latest.Name))"

    if ($ageInDays -le 1) {
        Add-TestResult -Category 'SessionLog' -TestName 'Latest session log' -Status 'Pass' -Message $ageStr
    } elseif ($ageInDays -le 7) {
        Add-TestResult -Category 'SessionLog' -TestName 'Latest session log' -Status 'Warn' -Message "Older than 1 day: $ageStr"
    } else {
        Add-TestResult -Category 'SessionLog' -TestName 'Latest session log' -Status 'Warn' -Message "Older than 7 days: $ageStr"
    }
    Add-TestResult -Category 'SessionLog' -TestName 'Total session logs' -Status 'Pass' -Message "$($sessionLogs.Count) file(s) found"
}

# ============================================================
# PHASES 21-36: CLUSTER OPERATIONAL HEALTH
# ============================================================
# These checks go beyond connectivity — they verify that SVMs, nodes, aggregates,
# volumes, SnapMirror, HA, disks, LIFs, and peers are all healthy.
# NOTE: SnapMirror commands use -max-records 50 to prevent hangs on large clusters
# (some clusters confirmed to hang indefinitely without this limit).

$clusterOpsCategories = @('SVM-State','Node-Health','Aggregates','Volumes','SnapMirror-Health',
    'SnapMirror-Lag','ClusterFaults','StorageErrors','SnapshotPolicy','iSCSI',
    'LIF-Status','HA-Failover','Disk-Health','ClusterPeer','NetPorts','S3-Server')

if ($SkipConnectivity) {
    Write-Host "`n── Phases 21–36: Cluster Operational Health (SKIPPED) ─────────" -ForegroundColor DarkGray
    foreach ($phase in $clusterOpsCategories) {
        Add-TestResult -Category $phase -TestName 'All tests' -Status 'Skip' -Message 'Skipped by -SkipConnectivity'
    }
} elseif (-not $configLoaded) {
    Write-Host "`n── Phases 21–36: Cluster Operational Health (SKIPPED — no config) ─" -ForegroundColor DarkGray
    Add-TestResult -Category 'ClusterOps' -TestName 'All tests' -Status 'Skip' -Message 'Config not loaded'
} else {
    # Resolve target clusters (supports -Cluster filter)
    $targetClusters = if ($Cluster) {
        $global:ONTAP_Clusters | Where-Object {
            $_.ClusterName -eq $Cluster -or $_.Alias -eq $Cluster -or $_.ConnectName -eq $Cluster
        }
    } else { $global:ONTAP_Clusters }

    if ($Cluster -and $targetClusters.Count -eq 0) {
        Add-TestResult -Category 'ClusterOps' -TestName 'Cluster filter' -Status 'Warn' `
            -Message "Cluster '$Cluster' not found in config.json — skipping operational checks"
    }

    foreach ($cl in $targetClusters) {
        $sshHost = if ($cl.FallbackIP) { $cl.FallbackIP } else { $cl.ConnectName }
        $clLabel = $cl.ClusterName

        Write-Host "`n══ Cluster Operational Health: $clLabel ═══════════════════════" -ForegroundColor Cyan

        # Quick TCP/22 reachability — skip all ops if unreachable
        $tcpReach = Test-NetConnection -ComputerName $sshHost -Port 22 -WarningAction SilentlyContinue -InformationLevel Quiet
        if (-not $tcpReach) {
            foreach ($cat in $clusterOpsCategories) {
                Add-TestResult -Category $cat -TestName $clLabel -Status 'Skip' -Message "TCP/22 unreachable ($sshHost)"
            }
            continue
        }

        # ── Phase 21: SVM State ───────────────────────────────────────
        Write-Host "  ── SVM State ──" -ForegroundColor White
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $svmOut, $rc = Invoke-ClusterSsh -Host_ $sshHost -Cmd 'vserver show -type data -fields vserver,admin-state,operational-state' -TimeoutSec 45
            $sw.Stop()
            if ($rc -ne 0) {
                Add-TestResult -Category 'SVM-State' -TestName $clLabel -Status 'Fail' -Message "SSH exit $rc" -DurationMs $sw.ElapsedMilliseconds
            } else {
                $downSvms    = @()
                $allDataSvms = 0
                foreach ($line in (Get-OntapDataLines $svmOut)) {
                    if ($line -match '^\s*(\S+)\s+(\S+)\s+(\S+)\s*$') {
                        $svmName  = $Matches[1]
                        $adminSt  = $Matches[2]
                        $operSt   = $Matches[3]
                        if ($svmName -match '^---') { continue }
                        $allDataSvms++
                        if ($operSt -ne 'running') { $downSvms += "$svmName (admin=$adminSt oper=$operSt)" }
                    }
                }
                if ($downSvms.Count -gt 0) {
                    Add-TestResult -Category 'SVM-State' -TestName $clLabel -Status 'Warn' `
                        -Message "$($downSvms.Count) SVM(s) not running: $($downSvms -join ', ')" -DurationMs $sw.ElapsedMilliseconds
                } else {
                    Add-TestResult -Category 'SVM-State' -TestName $clLabel -Status 'Pass' `
                        -Message "All $allDataSvms data SVM(s) running" -DurationMs $sw.ElapsedMilliseconds
                }
            }
        } catch {
            $sw.Stop()
            Add-TestResult -Category 'SVM-State' -TestName $clLabel -Status 'Fail' -Message $_.Exception.Message -DurationMs $sw.ElapsedMilliseconds
        }

        # ── Phase 22: Node Health ─────────────────────────────────────
        Write-Host "  ── Node Health ──" -ForegroundColor White
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $nodeOut, $rc = Invoke-ClusterSsh -Host_ $sshHost -Cmd 'cluster show -fields node,health,eligibility'
            $sw.Stop()
            $unhealthyNodes = @()
            $totalNodes     = 0
            foreach ($line in (Get-OntapDataLines $nodeOut)) {
                if ($line -match '^\s*(\S+)\s+(true|false)\s+(true|false)') {
                    $totalNodes++
                    if ($Matches[2] -ne 'true') { $unhealthyNodes += $Matches[1] }
                }
            }
            if ($unhealthyNodes.Count -gt 0) {
                Add-TestResult -Category 'Node-Health' -TestName $clLabel -Status 'Fail' `
                    -Message "Unhealthy node(s): $($unhealthyNodes -join ', ')" -DurationMs $sw.ElapsedMilliseconds
            } elseif ($totalNodes -eq 0) {
                Add-TestResult -Category 'Node-Health' -TestName $clLabel -Status 'Warn' `
                    -Message 'Could not parse node output' -DurationMs $sw.ElapsedMilliseconds
            } else {
                Add-TestResult -Category 'Node-Health' -TestName $clLabel -Status 'Pass' `
                    -Message "All $totalNodes node(s) healthy" -DurationMs $sw.ElapsedMilliseconds
            }
        } catch {
            $sw.Stop()
            Add-TestResult -Category 'Node-Health' -TestName $clLabel -Status 'Fail' -Message $_.Exception.Message -DurationMs $sw.ElapsedMilliseconds
        }

        # ── Phase 23: Aggregate Utilization ───────────────────────────
        Write-Host "  ── Aggregate Utilization ──" -ForegroundColor White
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $aggrOut, $rc = Invoke-ClusterSsh -Host_ $sshHost -Cmd 'aggr show -fields aggregate,size,usedsize,availsize,percent-used,state'
            $sw.Stop()
            $aggrIssues = @()
            foreach ($line in (Get-OntapDataLines $aggrOut)) {
                if ($line -match '^\s*(\S+)\s+\S+\s+\S+\s+\S+\s+(\d+)\s+(\S+)') {
                    $aggrName = $Matches[1]; $pctUsed = [int]$Matches[2]; $state = $Matches[3]
                    if ($state -ne 'online') {
                        Add-TestResult -Category 'Aggregates' -TestName "$clLabel / $aggrName" -Status 'Fail' -Message "State: $state"
                    } elseif ($pctUsed -ge $AggFailPct) {
                        $aggrIssues += $aggrName
                        Add-TestResult -Category 'Aggregates' -TestName "$clLabel / $aggrName" -Status 'Fail' -Message "$pctUsed% used (>= ${AggFailPct}%)"
                    } elseif ($pctUsed -ge $AggWarnPct) {
                        $aggrIssues += $aggrName
                        Add-TestResult -Category 'Aggregates' -TestName "$clLabel / $aggrName" -Status 'Warn' -Message "$pctUsed% used (>= ${AggWarnPct}%)"
                    }
                }
            }
            if ($aggrIssues.Count -eq 0) {
                Add-TestResult -Category 'Aggregates' -TestName "$clLabel / summary" -Status 'Pass' `
                    -Message "All aggregates below ${AggWarnPct}%" -DurationMs $sw.ElapsedMilliseconds
            }
        } catch {
            $sw.Stop()
            Add-TestResult -Category 'Aggregates' -TestName $clLabel -Status 'Fail' -Message $_.Exception.Message -DurationMs $sw.ElapsedMilliseconds
        }

        # ── Phase 24: Volume Utilization ──────────────────────────────
        Write-Host "  ── Volume Utilization ──" -ForegroundColor White
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $volOut, $rc = Invoke-ClusterSsh -Host_ $sshHost -Cmd 'vol show -fields vserver,volume,percent-used,state -max-records 500'
            $sw.Stop()
            $volOver    = @()
            $volOffline = @()
            foreach ($line in (Get-OntapDataLines $volOut)) {
                if ($line -match '^\s*(\S+)\s+(\S+)\s+(\S+)\s+(\d+)%?\s*$') {
                    $vserver = $Matches[1]; $volName = $Matches[2]; $state = $Matches[3]; $pctUsed = [int]$Matches[4]
                    if ($volName -match '^vol0$|^MDV_') { continue }
                    if ($state -ne 'online') {
                        $volOffline += "$vserver/$volName ($state)"
                    } elseif ($pctUsed -ge $VolFailPct) {
                        $volOver += $volName
                        Add-TestResult -Category 'Volumes' -TestName "$clLabel / $vserver/$volName" -Status 'Fail' -Message "$pctUsed% used (>= ${VolFailPct}%)"
                    } elseif ($pctUsed -ge $VolWarnPct) {
                        $volOver += $volName
                        Add-TestResult -Category 'Volumes' -TestName "$clLabel / $vserver/$volName" -Status 'Warn' -Message "$pctUsed% used (>= ${VolWarnPct}%)"
                    }
                }
            }
            foreach ($v in $volOffline) {
                Add-TestResult -Category 'Volumes' -TestName "$clLabel / $v" -Status 'Warn' -Message 'Volume not online'
            }
            if ($volOver.Count -eq 0 -and $volOffline.Count -eq 0) {
                Add-TestResult -Category 'Volumes' -TestName "$clLabel / summary" -Status 'Pass' `
                    -Message "All volumes below ${VolWarnPct}%" -DurationMs $sw.ElapsedMilliseconds
            }
        } catch {
            $sw.Stop()
            Add-TestResult -Category 'Volumes' -TestName $clLabel -Status 'Fail' -Message $_.Exception.Message -DurationMs $sw.ElapsedMilliseconds
        }

        # ── Phase 25: SnapMirror Health ───────────────────────────────
        # IMPORTANT: -max-records 50 is MANDATORY — some clusters hang without it.
        Write-Host "  ── SnapMirror Health ──" -ForegroundColor White
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $smOut, $rc = Invoke-ClusterSsh -Host_ $sshHost -Cmd 'snapmirror show -health false -fields source-path,destination-path,state,status,health -max-records 50'
            $sw.Stop()
            $unhealthyRels = $smOut | Where-Object { $_ -match '^\s*\S+:\S+' -and $_ -notmatch '^Source' }
            if ($unhealthyRels.Count -eq 0) {
                Add-TestResult -Category 'SnapMirror-Health' -TestName $clLabel -Status 'Pass' `
                    -Message 'No unhealthy SnapMirror relationships' -DurationMs $sw.ElapsedMilliseconds
            } else {
                Add-TestResult -Category 'SnapMirror-Health' -TestName $clLabel -Status 'Warn' `
                    -Message "$($unhealthyRels.Count) unhealthy relationship(s)" -DurationMs $sw.ElapsedMilliseconds
                foreach ($rel in ($unhealthyRels | Select-Object -First 5)) {
                    Add-TestResult -Category 'SnapMirror-Health' -TestName "$clLabel / relationship" -Status 'Warn' -Message ($rel.Trim())
                }
            }
        } catch {
            $sw.Stop()
            Add-TestResult -Category 'SnapMirror-Health' -TestName $clLabel -Status 'Fail' -Message $_.Exception.Message -DurationMs $sw.ElapsedMilliseconds
        }

        # ── Phase 26: SnapMirror Lag ──────────────────────────────────
        Write-Host "  ── SnapMirror Lag ──" -ForegroundColor White
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $lagOut, $rc = Invoke-ClusterSsh -Host_ $sshHost -Cmd 'snapmirror show -fields destination-path,lag-time -max-records 50'
            $sw.Stop()
            $lagIssues = @()
            foreach ($line in (Get-OntapDataLines $lagOut)) {
                if ($line -match '^\s*(\S+:\S+)\s+(P\d+DT\d+H\d+M\d+S|\d+:\d+:\d+)\s*$') {
                    $destPath = $Matches[1]; $lagHours = ConvertTo-Hours $Matches[2]
                    if ($lagHours -ge $SnapLagFailHours) {
                        $lagIssues += $destPath
                        Add-TestResult -Category 'SnapMirror-Lag' -TestName "$clLabel / $destPath" -Status 'Fail' -Message "Lag: ${lagHours}h (>= ${SnapLagFailHours}h)"
                    } elseif ($lagHours -ge $SnapLagWarnHours) {
                        $lagIssues += $destPath
                        Add-TestResult -Category 'SnapMirror-Lag' -TestName "$clLabel / $destPath" -Status 'Warn' -Message "Lag: ${lagHours}h (>= ${SnapLagWarnHours}h)"
                    }
                }
            }
            if ($lagIssues.Count -eq 0) {
                Add-TestResult -Category 'SnapMirror-Lag' -TestName "$clLabel / summary" -Status 'Pass' `
                    -Message "All relationships lag < ${SnapLagWarnHours}h" -DurationMs $sw.ElapsedMilliseconds
            }
        } catch {
            $sw.Stop()
            Add-TestResult -Category 'SnapMirror-Lag' -TestName $clLabel -Status 'Fail' -Message $_.Exception.Message -DurationMs $sw.ElapsedMilliseconds
        }

        # ── Phase 27: Active Cluster Faults ───────────────────────────
        Write-Host "  ── Cluster Faults ──" -ForegroundColor White
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $faultOut, $rc = Invoke-ClusterSsh -Host_ $sshHost -Cmd 'system health alert show -fields node,monitor,condition,severity'
            $sw.Stop()
            $faultLines = $faultOut | Where-Object { $_ -match '^\s*\S+\s+\S+\s+' -and $_ -notmatch '^Node|^---' }
            if ($faultLines.Count -eq 0) {
                Add-TestResult -Category 'ClusterFaults' -TestName $clLabel -Status 'Pass' `
                    -Message 'No active health alerts' -DurationMs $sw.ElapsedMilliseconds
            } else {
                $sevCounts = @{}
                foreach ($fl in $faultLines) {
                    if ($fl -match '(critical|error|warning|notice)') { $sevCounts[$Matches[1]] = ($sevCounts[$Matches[1]] ?? 0) + 1 }
                }
                $hasCritical = $sevCounts['critical'] -gt 0 -or $sevCounts['error'] -gt 0
                $status  = if ($hasCritical) { 'Fail' } else { 'Warn' }
                $summary = ($sevCounts.GetEnumerator() | ForEach-Object { "$($_.Value) $($_.Key)" }) -join ', '
                Add-TestResult -Category 'ClusterFaults' -TestName $clLabel -Status $status `
                    -Message "$($faultLines.Count) alert(s): $summary" -DurationMs $sw.ElapsedMilliseconds
            }
        } catch {
            $sw.Stop()
            Add-TestResult -Category 'ClusterFaults' -TestName $clLabel -Status 'Fail' -Message $_.Exception.Message -DurationMs $sw.ElapsedMilliseconds
        }

        # ── Phase 28: Storage Errors ──────────────────────────────────
        Write-Host "  ── Storage Errors ──" -ForegroundColor White
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $storErrOut, $rc = Invoke-ClusterSsh -Host_ $sshHost -Cmd 'storage errors show'
            $sw.Stop()
            $storErrLines = $storErrOut | Where-Object { $_ -match '\S' -and $_ -notmatch '^There are no|^\s*$|^Storage errors' }
            if ($storErrLines.Count -eq 0) {
                Add-TestResult -Category 'StorageErrors' -TestName $clLabel -Status 'Pass' `
                    -Message 'No storage errors' -DurationMs $sw.ElapsedMilliseconds
            } else {
                Add-TestResult -Category 'StorageErrors' -TestName $clLabel -Status 'Warn' `
                    -Message "$($storErrLines.Count) storage error line(s)" -DurationMs $sw.ElapsedMilliseconds
            }
        } catch {
            $sw.Stop()
            Add-TestResult -Category 'StorageErrors' -TestName $clLabel -Status 'Fail' -Message $_.Exception.Message -DurationMs $sw.ElapsedMilliseconds
        }

        # ── Phase 29: Snapshot Policy Coverage ────────────────────────
        Write-Host "  ── Snapshot Policy Coverage ──" -ForegroundColor White
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $snapPolOut, $rc = Invoke-ClusterSsh -Host_ $sshHost -Cmd 'vol show -fields vserver,volume,snapshot-policy -max-records 300'
            $sw.Stop()
            $noPolicyVols = @()
            foreach ($line in (Get-OntapDataLines $snapPolOut)) {
                if ($line -match '^\s*(\S+)\s+(\S+)\s+(none|-)\s*$') {
                    if ($Matches[2] -notmatch '^vol0$|^MDV_') { $noPolicyVols += "$($Matches[1])/$($Matches[2])" }
                }
            }
            if ($noPolicyVols.Count -eq 0) {
                Add-TestResult -Category 'SnapshotPolicy' -TestName $clLabel -Status 'Pass' `
                    -Message 'All volumes have a snapshot policy' -DurationMs $sw.ElapsedMilliseconds
            } else {
                Add-TestResult -Category 'SnapshotPolicy' -TestName $clLabel -Status 'Warn' `
                    -Message "$($noPolicyVols.Count) volume(s) with no policy: $($noPolicyVols[0..4] -join ', ')$(if ($noPolicyVols.Count -gt 5) { ' ...' })" `
                    -DurationMs $sw.ElapsedMilliseconds
            }
        } catch {
            $sw.Stop()
            Add-TestResult -Category 'SnapshotPolicy' -TestName $clLabel -Status 'Fail' -Message $_.Exception.Message -DurationMs $sw.ElapsedMilliseconds
        }

        # ── Phase 30: iSCSI Sessions ──────────────────────────────────
        Write-Host "  ── iSCSI Sessions ──" -ForegroundColor White
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $iscsiSvmOut, $rc = Invoke-ClusterSsh -Host_ $sshHost -Cmd 'vserver iscsi show -fields vserver,target-name'
            $sw.Stop()
            $iscsiSvms = @()
            foreach ($line in (Get-OntapDataLines $iscsiSvmOut)) {
                if ($line -match '^\s*(\S+)\s+iqn\.') { $iscsiSvms += $Matches[1] }
            }
            if ($iscsiSvms.Count -eq 0) {
                Add-TestResult -Category 'iSCSI' -TestName $clLabel -Status 'Pass' `
                    -Message 'No iSCSI SVMs configured' -DurationMs $sw.ElapsedMilliseconds
            } else {
                foreach ($svm in $iscsiSvms) {
                    $sessSw = [System.Diagnostics.Stopwatch]::StartNew()
                    $sessOut, $sessRc = Invoke-ClusterSsh -Host_ $sshHost -Cmd "iscsi session show -vserver $svm"
                    $sessSw.Stop()
                    $sessCount = ($sessOut | Where-Object { $_ -match '^\s*\d+\s+' }).Count
                    if ($sessCount -eq 0) {
                        Add-TestResult -Category 'iSCSI' -TestName "$clLabel / $svm" -Status 'Warn' -Message 'No active sessions' -DurationMs $sessSw.ElapsedMilliseconds
                    } else {
                        Add-TestResult -Category 'iSCSI' -TestName "$clLabel / $svm" -Status 'Pass' -Message "$sessCount active session(s)" -DurationMs $sessSw.ElapsedMilliseconds
                    }
                }
            }
        } catch {
            $sw.Stop()
            Add-TestResult -Category 'iSCSI' -TestName $clLabel -Status 'Fail' -Message $_.Exception.Message -DurationMs $sw.ElapsedMilliseconds
        }

        # ── Phase 31: LIF Home Port Status ────────────────────────────
        Write-Host "  ── LIF Home Port ──" -ForegroundColor White
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $lifOut, $rc = Invoke-ClusterSsh -Host_ $sshHost -Cmd 'net int show -fields vserver,lif,home-node,home-port,curr-node,curr-port,status-oper,is-home'
            $sw.Stop()
            $notHome   = @()
            $lifDown   = @()
            $totalLifs = 0
            foreach ($line in (Get-OntapDataLines $lifOut)) {
                # Column order: vserver lif home-node home-port curr-node curr-port status-oper is-home
                if ($line -match '^\s*(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(true|false)') {
                    $totalLifs++
                    $vserver = $Matches[1]; $lifName = $Matches[2]
                    $homeNode = $Matches[3]; $homePort = $Matches[4]
                    $currNode = $Matches[5]; $currPort = $Matches[6]
                    $opStatus = $Matches[7]; $isHome = $Matches[8]
                    if ($opStatus -ne 'up') {
                        $lifDown += "$vserver/$lifName ($opStatus)"
                    } elseif ($isHome -eq 'false') {
                        $notHome += "$vserver/$lifName (on ${currNode}:${currPort}, home=${homeNode}:${homePort})"
                    }
                }
            }
            foreach ($ld in $lifDown) {
                Add-TestResult -Category 'LIF-Status' -TestName "$clLabel / $ld" -Status 'Fail' -Message 'LIF operationally down'
            }
            foreach ($nh in $notHome) {
                Add-TestResult -Category 'LIF-Status' -TestName "$clLabel / not-home" -Status 'Warn' -Message $nh
            }
            if ($lifDown.Count -eq 0 -and $notHome.Count -eq 0) {
                Add-TestResult -Category 'LIF-Status' -TestName "$clLabel / summary" -Status 'Pass' `
                    -Message "All $totalLifs LIF(s) up and at home" -DurationMs $sw.ElapsedMilliseconds
            }
        } catch {
            $sw.Stop()
            Add-TestResult -Category 'LIF-Status' -TestName $clLabel -Status 'Fail' -Message $_.Exception.Message -DurationMs $sw.ElapsedMilliseconds
        }

        # ── Phase 32: HA / Failover Status ────────────────────────────
        Write-Host "  ── HA / Failover ──" -ForegroundColor White
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $haOut, $rc = Invoke-ClusterSsh -Host_ $sshHost -Cmd 'storage failover show -fields node,partner-name,enabled,state-description'
            $sw.Stop()
            $haIssues = @()
            $haNodes  = 0
            foreach ($line in (Get-OntapDataLines $haOut)) {
                if ($line -match '^\s*(\S+)\s+(\S+)\s+(true|false)\s+(.+?)\s*$') {
                    $haNodes++
                    $nodeName  = $Matches[1]; $haEnabled = $Matches[3]; $stateDesc = $Matches[4].Trim()
                    if ($haEnabled -ne 'true') {
                        $haIssues += "$nodeName — HA disabled"
                    } elseif ($stateDesc -notmatch 'Connected to|waiting for giveback') {
                        $haIssues += "$nodeName — $stateDesc"
                    }
                }
            }
            if ($haIssues.Count -gt 0) {
                foreach ($hi in $haIssues) {
                    Add-TestResult -Category 'HA-Failover' -TestName "$clLabel / $($hi.Split(' — ')[0])" -Status 'Fail' -Message $hi
                }
            } elseif ($haNodes -eq 0) {
                # ONTAP Select single-node clusters have no HA partner
                $isSelect = $cl.PSObject.Properties['ONTAP_Select'] -and $cl.ONTAP_Select
                if ($isSelect) {
                    Add-TestResult -Category 'HA-Failover' -TestName $clLabel -Status 'Pass' `
                        -Message 'ONTAP Select — no HA partner expected' -DurationMs $sw.ElapsedMilliseconds
                } else {
                    Add-TestResult -Category 'HA-Failover' -TestName $clLabel -Status 'Warn' -Message 'Could not parse HA status' -DurationMs $sw.ElapsedMilliseconds
                }
            } else {
                Add-TestResult -Category 'HA-Failover' -TestName $clLabel -Status 'Pass' `
                    -Message "All $haNodes node(s) HA connected" -DurationMs $sw.ElapsedMilliseconds
            }
        } catch {
            $sw.Stop()
            Add-TestResult -Category 'HA-Failover' -TestName $clLabel -Status 'Fail' -Message $_.Exception.Message -DurationMs $sw.ElapsedMilliseconds
        }

        # ── Phase 33: Disk Health ─────────────────────────────────────
        Write-Host "  ── Disk Health ──" -ForegroundColor White
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $brokenOut, $rc = Invoke-ClusterSsh -Host_ $sshHost -Cmd 'storage disk show -container-type broken -fields disk,owner,shelf,bay'
            $sw.Stop()
            $brokenLines = $brokenOut | Where-Object { $_ -match '^\s*\d+\.' -and $_ -notmatch '^---' }
            if ($brokenLines.Count -gt 0) {
                Add-TestResult -Category 'Disk-Health' -TestName "$clLabel / broken disks" -Status 'Fail' `
                    -Message "$($brokenLines.Count) broken disk(s)" -DurationMs $sw.ElapsedMilliseconds
                foreach ($bd in ($brokenLines | Select-Object -First 5)) {
                    Add-TestResult -Category 'Disk-Health' -TestName "$clLabel / disk" -Status 'Fail' -Message ($bd.Trim())
                }
            } else {
                Add-TestResult -Category 'Disk-Health' -TestName "$clLabel / broken disks" -Status 'Pass' `
                    -Message 'No broken disks' -DurationMs $sw.ElapsedMilliseconds
            }

            # Spare count per node
            $sw2 = [System.Diagnostics.Stopwatch]::StartNew()
            $spareOut, $rc2 = Invoke-ClusterSsh -Host_ $sshHost -Cmd 'storage disk show -container-type spare -fields disk,owner'
            $sw2.Stop()
            $sparesByNode = @{}
            foreach ($line in $spareOut) {
                if ($line -match '^\s*\S+\s+(\S+)\s*$' -and $Matches[1] -notmatch '^---$|^Owner$') {
                    $sparesByNode[$Matches[1]] = ($sparesByNode[$Matches[1]] ?? 0) + 1
                }
            }
            if ($sparesByNode.Count -gt 0) {
                foreach ($kv in $sparesByNode.GetEnumerator()) {
                    $spSt = if ($kv.Value -lt 1) { 'Fail' } elseif ($kv.Value -lt 2) { 'Warn' } else { 'Pass' }
                    Add-TestResult -Category 'Disk-Health' -TestName "$clLabel / spares: $($kv.Key)" -Status $spSt `
                        -Message "$($kv.Value) spare disk(s)" -DurationMs $sw2.ElapsedMilliseconds
                }
            } else {
                Add-TestResult -Category 'Disk-Health' -TestName "$clLabel / spares" -Status 'Pass' `
                    -Message 'No spare disks (normal for ADP/partitioned)' -DurationMs $sw2.ElapsedMilliseconds
            }
        } catch {
            $sw.Stop()
            Add-TestResult -Category 'Disk-Health' -TestName $clLabel -Status 'Fail' -Message $_.Exception.Message -DurationMs $sw.ElapsedMilliseconds
        }

        # ── Phase 34: Cluster Peer Health ─────────────────────────────
        Write-Host "  ── Cluster Peer ──" -ForegroundColor White
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $peerOut, $rc = Invoke-ClusterSsh -Host_ $sshHost -Cmd 'cluster peer show -fields remote-cluster-name,availability'
            $sw.Stop()
            $peerIssues = @()
            $peerCount  = 0
            foreach ($line in (Get-OntapDataLines $peerOut)) {
                if ($line -match '^\s*(\S+)\s+(Available|Unavailable|Partially|Pending)\s*$') {
                    $peerCount++
                    if ($Matches[2] -ne 'Available') { $peerIssues += "$($Matches[1]) ($($Matches[2]))" }
                }
            }
            if ($peerCount -eq 0) {
                Add-TestResult -Category 'ClusterPeer' -TestName $clLabel -Status 'Pass' -Message 'No peers configured' -DurationMs $sw.ElapsedMilliseconds
            } elseif ($peerIssues.Count -gt 0) {
                Add-TestResult -Category 'ClusterPeer' -TestName $clLabel -Status 'Fail' `
                    -Message "Unhealthy peer(s): $($peerIssues -join ', ')" -DurationMs $sw.ElapsedMilliseconds
            } else {
                Add-TestResult -Category 'ClusterPeer' -TestName $clLabel -Status 'Pass' `
                    -Message "$peerCount peer(s) all Available" -DurationMs $sw.ElapsedMilliseconds
            }
        } catch {
            $sw.Stop()
            Add-TestResult -Category 'ClusterPeer' -TestName $clLabel -Status 'Fail' -Message $_.Exception.Message -DurationMs $sw.ElapsedMilliseconds
        }

        # ── Phase 35: Network Port Health ─────────────────────────────
        Write-Host "  ── Network Ports ──" -ForegroundColor White
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $portOut, $rc = Invoke-ClusterSsh -Host_ $sshHost -Cmd 'net port show -fields node,port,link,speed-oper,health-status'
            $sw.Stop()
            $portIssues = @()
            $totalPorts = 0
            foreach ($line in (Get-OntapDataLines $portOut)) {
                # Column order: node port link speed-oper health-status
                if ($line -match '^\s*(\S+)\s+(\S+)\s+(up|down)\s+(\S+)\s+(\S+)\s*$') {
                    $totalPorts++
                    $pNode = $Matches[1]; $pPort = $Matches[2]; $pLink = $Matches[3]; $pHealth = $Matches[5]
                    if ($pHealth -ne 'healthy' -and $pPort -notmatch '^e0M$|^lo$') {
                        $portIssues += "${pNode}:${pPort} (link=$pLink health=$pHealth)"
                    }
                }
            }
            if ($portIssues.Count -gt 0) {
                Add-TestResult -Category 'NetPorts' -TestName $clLabel -Status 'Warn' `
                    -Message "$($portIssues.Count) unhealthy port(s): $($portIssues[0..2] -join ', ')$(if ($portIssues.Count -gt 3) { ' ...' })" `
                    -DurationMs $sw.ElapsedMilliseconds
            } else {
                Add-TestResult -Category 'NetPorts' -TestName $clLabel -Status 'Pass' `
                    -Message "All $totalPorts port(s) healthy" -DurationMs $sw.ElapsedMilliseconds
            }
        } catch {
            $sw.Stop()
            Add-TestResult -Category 'NetPorts' -TestName $clLabel -Status 'Fail' -Message $_.Exception.Message -DurationMs $sw.ElapsedMilliseconds
        }

        # ── Phase 36: S3 Server Status (conditional) ──────────────────
        if ($configLoaded -and $global:Config.S3_Config -and $global:Config.S3_Config.Clusters) {
            $s3Entry = $global:Config.S3_Config.Clusters.PSObject.Properties | Where-Object {
                $_.Name -eq $cl.ClusterName -or $_.Name -eq $cl.Alias -or $_.Name -eq $cl.ConnectName
            }
            if ($s3Entry) {
                Write-Host "  ── S3 Server ──" -ForegroundColor White
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                try {
                    $s3Out, $rc = Invoke-ClusterSsh -Host_ $sshHost -Cmd 'vserver object-store-server show -fields vserver,object-store-server,is-http-enabled,is-https-enabled'
                    $sw.Stop()
                    $s3Servers = $s3Out | Where-Object { $_ -match '^\s*\S+\s+\S+\s+(true|false)\s+(true|false)' -and $_ -notmatch '^Vserver|^---' }
                    if ($s3Servers.Count -gt 0) {
                        Add-TestResult -Category 'S3-Server' -TestName $clLabel -Status 'Pass' `
                            -Message "$($s3Servers.Count) S3 server(s) configured" -DurationMs $sw.ElapsedMilliseconds
                    } else {
                        Add-TestResult -Category 'S3-Server' -TestName $clLabel -Status 'Warn' `
                            -Message 'S3_Config exists but no S3 servers found' -DurationMs $sw.ElapsedMilliseconds
                    }
                } catch {
                    $sw.Stop()
                    Add-TestResult -Category 'S3-Server' -TestName $clLabel -Status 'Fail' -Message $_.Exception.Message -DurationMs $sw.ElapsedMilliseconds
                }
            }
        }

    }  # end foreach cluster
}  # end cluster ops block

# ============================================================
# REPORT
# ============================================================
Write-Host "`n╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host   "║                     SUMMARY REPORT                          ║" -ForegroundColor Cyan
Write-Host   "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

$totalPass = ($results | Where-Object Status -eq 'Pass').Count
$totalFail = ($results | Where-Object Status -eq 'Fail').Count
$totalWarn = ($results | Where-Object Status -eq 'Warn').Count
$totalSkip = ($results | Where-Object Status -eq 'Skip').Count
$total     = $results.Count

Write-Host "`nTotal: $total tests — " -NoNewline
Write-Host "$totalPass Pass" -ForegroundColor Green -NoNewline
Write-Host " | " -NoNewline
Write-Host "$totalFail Fail" -ForegroundColor $(if ($totalFail) { 'Red' } else { 'Green' }) -NoNewline
Write-Host " | " -NoNewline
Write-Host "$totalWarn Warn" -ForegroundColor $(if ($totalWarn) { 'Yellow' } else { 'Green' }) -NoNewline
Write-Host " | " -NoNewline
Write-Host "$totalSkip Skip" -ForegroundColor DarkGray
Write-Host ''

# Per-category summary
$categories = $results | Group-Object Category | Sort-Object Name
$summaryTable = foreach ($cat in $categories) {
    [PSCustomObject]@{
        Category = $cat.Name
        Total    = $cat.Count
        Pass     = ($cat.Group | Where-Object Status -eq 'Pass').Count
        Fail     = ($cat.Group | Where-Object Status -eq 'Fail').Count
        Warn     = ($cat.Group | Where-Object Status -eq 'Warn').Count
        Skip     = ($cat.Group | Where-Object Status -eq 'Skip').Count
    }
}
$summaryTable | Format-Table -AutoSize

# Show failures detail
if ($totalFail -gt 0) {
    Write-Host "── Failures Detail ─────────────────────────────────────────────" -ForegroundColor Red
    $results | Where-Object Status -eq 'Fail' | ForEach-Object {
        Write-Host "  [FAIL] $($_.Category) / $($_.TestName)" -ForegroundColor Red
        Write-Host "         $($_.Message)" -ForegroundColor DarkGray
    }
    Write-Host ''
}

# Show warnings detail
if ($totalWarn -gt 0) {
    Write-Host "── Warnings Detail ─────────────────────────────────────────────" -ForegroundColor Yellow
    $results | Where-Object Status -eq 'Warn' | ForEach-Object {
        Write-Host "  [WARN] $($_.Category) / $($_.TestName)" -ForegroundColor Yellow
        Write-Host "         $($_.Message)" -ForegroundColor DarkGray
    }
    Write-Host ''
}

# Export CSV
$results | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8
Write-Host "CSV report : $csvFile" -ForegroundColor Cyan
Write-Host "Transcript : $logFile" -ForegroundColor Cyan

# Stop transcript
Stop-Transcript | Out-Null

# Exit code
$exitCode = if ($totalFail -gt 0) { 1 } else { 0 }
Write-Host "`nExit code: $exitCode`n" -ForegroundColor $(if ($exitCode) { 'Red' } else { 'Green' })
exit $exitCode
