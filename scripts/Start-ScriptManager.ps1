<#
.SYNOPSIS
    Interactive launcher for workspace automation scripts.
.DESCRIPTION
    Presents a menu of available ONTAP automation scripts.
    On Windows, uses Out-GridView for a GUI dropdown; falls back to a
    numbered console menu on non-Windows or when -Console is specified.
.EXAMPLE
    Start-ScriptManager                # GUI grid view
    Start-ScriptManager -Console       # Console numbered list
    Start-ScriptManager -Filter "share" # Pre-filter by keyword
#>
[CmdletBinding()]
param(
    [switch]$Console,
    [string]$Filter
)

$ErrorActionPreference = 'Stop'
$workspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

# --- Script registry -------------------------------------------------------
# Each entry: Name, Description, Script (relative to workspace root), and
# optional DefaultParams hashtable for guided execution.
$scripts = @(
    [pscustomobject]@{
        Name        = 'Share Migration — Export'
        Description = 'Export all SMB shares + ACLs from source SVMs to JSON snapshot'
        Script      = 'scripts\share-migration\Invoke-ShareMigration.ps1'
        DefaultArgs = '-Mode Export'
        Category    = 'CIFS / Shares'
    }
    [pscustomobject]@{
        Name        = 'Share Migration — Import'
        Description = 'Import shares + ACLs from a JSON snapshot to destination SVMs'
        Script      = 'scripts\share-migration\Invoke-ShareMigration.ps1'
        DefaultArgs = '-Mode Import'
        Category    = 'CIFS / Shares'
    }
    [pscustomobject]@{
        Name        = 'Share Migration — Preflight'
        Description = 'Run preflight checks (DC auth, test group, test share) before real migration'
        Script      = 'scripts\share-migration\Invoke-ShareMigration.ps1'
        DefaultArgs = '-Mode Preflight -ApprovePreflight'
        Category    = 'CIFS / Shares'
    }
    [pscustomobject]@{
        Name        = 'Share Migration — Sync'
        Description = 'Export + Import in a single run (end-to-end migration)'
        Script      = 'scripts\share-migration\Invoke-ShareMigration.ps1'
        DefaultArgs = '-Mode Sync'
        Category    = 'CIFS / Shares'
    }
    [pscustomobject]@{
        Name        = 'Share Migration — Domain Migration'
        Description = 'Full circle: Export → Stop CIFS (leave domain) → Join new domain → Import shares'
        Script      = 'scripts\share-migration\Invoke-ShareMigration.ps1'
        DefaultArgs = '-Mode DomainMigration'
        Category    = 'CIFS / Shares'
    }
    [pscustomobject]@{
        Name        = 'Share Migration — Test Credentials'
        Description = 'Validate domain credentials via LDAP (no CIFS required). Target: Source, Destination, or Both'
        Script      = 'scripts\share-migration\Invoke-ShareMigration.ps1'
        DefaultArgs = '-Mode TestCredentials -Target Both'
        Category    = 'CIFS / Shares'
    }
    [pscustomobject]@{
        Name        = 'Share Migration — Rollback'
        Description = 'Roll back a failed domain migration: restore DNS, CIFS, preferred DC, and shares to source domain'
        Script      = 'scripts\share-migration\Invoke-ShareMigration.ps1'
        DefaultArgs = '-Mode Rollback'
        Category    = 'CIFS / Shares'
    }
    [pscustomobject]@{
        Name        = 'Share Migration — Reset CIFS Password (Source)'
        Description = 'Reset CIFS machine account password on source SVM(s)'
        Script      = 'scripts\share-migration\Invoke-ShareMigration.ps1'
        DefaultArgs = '-Mode ResetCifsPassword -Target Source'
        Category    = 'CIFS / Shares'
    }
    [pscustomobject]@{
        Name        = 'Share Migration — Reset CIFS Password (Destination)'
        Description = 'Reset CIFS machine account password on destination SVM(s)'
        Script      = 'scripts\share-migration\Invoke-ShareMigration.ps1'
        DefaultArgs = '-Mode ResetCifsPassword -Target Destination'
        Category    = 'CIFS / Shares'
    }
    [pscustomobject]@{
        Name        = 'NDMP Copy'
        Description = 'Storage-to-storage file copy between clusters via NDMP protocol'
        Script      = 'scripts\ndmp-copy\Ndmp_Copy.ps1'
        DefaultArgs = ''
        Category    = 'Data Migration'
    }
    [pscustomobject]@{
        Name        = 'Quota Manager'
        Description = 'View and resize qtree quota policies across clusters'
        Script      = 'scripts\quota\Clusters Quota Policy Manger.ps1'
        DefaultArgs = ''
        Category    = 'Quota'
    }
    [pscustomobject]@{
        Name        = 'SAS Diagnostics'
        Description = 'Collect SAS/disk/shelf health data for a cluster'
        Script      = 'scripts\disk\sas-diag.ps1'
        DefaultArgs = ''
        Category    = 'Health / Diagnostics'
    }
    [pscustomobject]@{
        Name        = 'Test RO User Connectivity'
        Description = 'Test read-only user connectivity to all configured clusters'
        Script      = 'scripts\testing\Test-NetappROUser.ps1'
        DefaultArgs = ''
        Category    = 'Testing'
    }
    [pscustomobject]@{
        Name        = 'Store New Credential'
        Description = 'Create a new AES-encrypted credential file in credentials/'
        Script      = 'scripts\credentials\New-Credential.ps1'
        DefaultArgs = ''
        Category    = 'Credentials'
    }
    [pscustomobject]@{
        Name        = 'S3 Bucket Provision (Ansible)'
        Description = 'Create S3 buckets on a cluster via Ansible playbook'
        Script      = 'ansible\s3-bucket-provision\Invoke-S3Provision.ps1'
        DefaultArgs = ''
        Category    = 'S3'
    }
)

# --- Filter ---
if ($Filter) {
    $scripts = $scripts | Where-Object {
        $_.Name -like "*$Filter*" -or $_.Description -like "*$Filter*" -or $_.Category -like "*$Filter*"
    }
    if (-not $scripts) {
        Write-Host "No scripts matched filter '$Filter'" -ForegroundColor Yellow
        return
    }
}

# --- Validate script files exist ---
$scripts = $scripts | Where-Object {
    $fullPath = Join-Path $workspaceRoot $_.Script
    if (-not (Test-Path -LiteralPath $fullPath)) {
        Write-Verbose "Skipping '$($_.Name)' — script not found: $fullPath"
        $false
    } else { $true }
}

if (-not $scripts) {
    Write-Host "No runnable scripts found in the workspace." -ForegroundColor Yellow
    return
}

# --- Selection UI ---
$selected = $null

if (-not $Console -and $IsWindows -ne $false) {
    # Try Out-GridView (available on Windows PowerShell and PS7 with WindowsCompatibility)
    try {
        $selected = $scripts |
            Select-Object Name, Category, Description, Script, DefaultArgs |
            Out-GridView -Title 'ONTAP Script Manager — Select a script to run' -PassThru
    }
    catch {
        Write-Verbose "Out-GridView not available, falling back to console menu"
        $Console = $true
    }
}

if ($Console -or -not $selected) {
    if (-not $Console) { return }  # User cancelled the grid view

    Write-Host "`n=== ONTAP Script Manager ===" -ForegroundColor Cyan
    Write-Host ""
    $i = 1
    foreach ($s in $scripts) {
        Write-Host "  [$i] " -NoNewline -ForegroundColor Green
        Write-Host "$($s.Name)" -NoNewline -ForegroundColor White
        Write-Host "  ($($s.Category))" -ForegroundColor DarkGray
        Write-Host "      $($s.Description)" -ForegroundColor Gray
        $i++
    }
    Write-Host ""
    Write-Host "  [0] Cancel" -ForegroundColor DarkYellow
    Write-Host ""

    $choice = Read-Host "Select script number"
    if ($choice -eq '0' -or [string]::IsNullOrWhiteSpace($choice)) {
        Write-Host "Cancelled." -ForegroundColor Yellow
        return
    }

    $idx = [int]$choice - 1
    if ($idx -lt 0 -or $idx -ge $scripts.Count) {
        Write-Host "Invalid selection." -ForegroundColor Red
        return
    }

    $selected = $scripts[$idx]
}

# --- Execute selected script ---
$scriptPath = Join-Path $workspaceRoot $selected.Script
Write-Host ""
Write-Host "Running: $($selected.Name)" -ForegroundColor Cyan
Write-Host "Script:  $scriptPath" -ForegroundColor DarkGray
if ($selected.DefaultArgs) {
    Write-Host "Args:    $($selected.DefaultArgs)" -ForegroundColor DarkGray
}
Write-Host ('-' * 60) -ForegroundColor DarkGray

if ($selected.DefaultArgs) {
    $expression = "& '$scriptPath' $($selected.DefaultArgs)"
    Invoke-Expression $expression
}
else {
    & $scriptPath
}
