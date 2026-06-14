# Load-Config.ps1 — Shared config loader for ONTAP automation scripts.
# Usage:  $rootDir = (Resolve-Path "$PSScriptRoot\..").Path   # or repo root
#         . "$rootDir\Load-Config.ps1"
# Falls back to $PSScriptRoot if $rootDir is not set.

if (-not $rootDir) {
    $rootDir = $PSScriptRoot
}

$global:ConfigPath = Join-Path $rootDir 'config.json'
$_templatePath     = Join-Path $rootDir 'config.template.json'

# --- Auto-copy template if config.json doesn't exist -----------------------
if (-not (Test-Path -LiteralPath $global:ConfigPath)) {
    if (Test-Path -LiteralPath $_templatePath) {
        Write-Host "config.json not found — creating from config.template.json ..." -ForegroundColor Yellow
        Copy-Item -LiteralPath $_templatePath -Destination $global:ConfigPath
        Write-Host "Created $global:ConfigPath — please edit it with your cluster details, then re-run." -ForegroundColor Yellow
        throw "Load-Config.ps1: config.json was just created from template. Edit it before running again."
    }
    else {
        throw "Load-Config.ps1: Neither config.json nor config.template.json found in $rootDir"
    }
}

# --- Load and validate -----------------------------------------------------
$global:Config = Get-Content -LiteralPath $global:ConfigPath -Raw | ConvertFrom-Json

# Guard: if the _comment field still contains the template marker, the user
# hasn't customised config.json yet.
if ($global:Config._comment -and $global:Config._comment -match 'Copy this file to config\.json') {
    throw "Load-Config.ps1: config.json still contains the template placeher. Edit it with your real cluster details before running."
}

# --- Personal modules (optional, from config.json) -------------------------
if ($global:Config.Personal_modules) {
    foreach ($_mod in $global:Config.Personal_modules) {
        if (Test-Path $_mod) {
            Import-Module $_mod -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- ONTAP clusters ---------------------------------------------------------
$global:ONTAP_Clusters = @()
foreach ($c in $global:Config.ONTAP_Clusters) {
    $obj = New-Object System.Object
    $obj | Add-Member -MemberType NoteProperty -Name 'ClusterName'  -Value $c.ClusterName
    $obj | Add-Member -MemberType NoteProperty -Name 'ConnectName'  -Value $c.ConnectName
    $obj | Add-Member -MemberType NoteProperty -Name 'Alias'        -Value $c.Alias
    $obj | Add-Member -MemberType NoteProperty -Name 'CsvPrefix'    -Value $c.CsvPrefix
    $obj | Add-Member -MemberType NoteProperty -Name 'Description'  -Value $c.Description
    $obj | Add-Member -MemberType NoteProperty -Name 'FallbackIP'   -Value $c.FallbackIP -Force
    $obj | Add-Member -MemberType NoteProperty -Name 'VIP'          -Value ([bool]$c.VIP) -Force
    $global:ONTAP_Clusters += $obj
}

# --- VIP / cluster selection helpers ----------------------------------------
# Scripts use: $targets = Get-OntapTargetClusters [-Cluster "Prod"] [-VIP]
# - No params     → all clusters
# - -VIP          → only VIP-marked clusters (or all if none are VIP)
# - -Cluster "X"  → specific cluster by Alias or ClusterName
function global:Get-OntapTargetClusters {
    [CmdletBinding()]
    param(
        [string]$Cluster,
        [switch]$VIP
    )
    if ($Cluster) {
        $match = $global:ONTAP_Clusters | Where-Object {
            $_.Alias -eq $Cluster -or $_.ClusterName -eq $Cluster -or $_.ConnectName -eq $Cluster
        }
        if (-not $match) { throw "Cluster '$Cluster' not found in config.json" }
        return @($match)
    }
    if ($VIP) {
        $vips = $global:ONTAP_Clusters | Where-Object { $_.VIP -eq $true }
        if ($vips) { return @($vips) }
        # Fallback: if no VIP marked, return all
        return @($global:ONTAP_Clusters)
    }
    return @($global:ONTAP_Clusters)
}

# --- ONTAP credential (Jenkins env vars or interactive fallback) ------------
# When Jenkins injects NETAPP_USER / NETAPP_PASS via withCredentials, build a
# PSCredential automatically.  On a dev machine the env vars won't exist, so
# scripts fall back to interactive Get-Credential.
$global:ONTAP_CredentialConfig = $global:Config.ONTAP_Credential
$global:ONTAP_Credential = $null

$_envUser = [System.Environment]::GetEnvironmentVariable($global:ONTAP_CredentialConfig.EnvVarUser)
$_envPass = [System.Environment]::GetEnvironmentVariable($global:ONTAP_CredentialConfig.EnvVarPass)

if (![string]::IsNullOrWhiteSpace($_envUser) -and ![string]::IsNullOrWhiteSpace($_envPass)) {
    $secPass = ConvertTo-SecureString $_envPass -AsPlainText -Force
    $global:ONTAP_Credential = New-Object System.Management.Automation.PSCredential($_envUser, $secPass)
    Write-Host "INFO: ONTAP credential loaded from Jenkins env vars ($($global:ONTAP_CredentialConfig.EnvVarUser))" -ForegroundColor Green
}
else {
    Write-Host "INFO: Jenkins ONTAP env vars not set — will fall back to interactive Get-Credential when needed" -ForegroundColor Yellow
}

# --- Generic CSV helper (must be defined before per-cluster wrappers) -------
function global:Invoke-OntapCsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$SshFunction,
        [Parameter(Mandatory=$true)] [string]$Command,
        [string[]]$Headers
    )
    $wrapped = "set diagnostic -confirmations off -showseparator ','; row 0 ; $Command"
    $output = & $SshFunction -Command $wrapped | awk 'NR>8' | ForEach-Object { $_ -replace "'","" }
    if ($Headers) {
        $output | ConvertFrom-Csv -Header $Headers
    } else {
        $output | ConvertFrom-Csv
    }
}

# --- Auto-generate connect / SSH / CSV functions per cluster ----------------
# For each cluster in config.json, creates up to 4 items:
#   1) <ConnectName>    → Connect-NcController function
#   2) <ConnectName>-s  → SSH function (admin@host)
#   3) Get-<CsvPrefix>Csv → Invoke-OntapCsv wrapper
#   4) Alias + Alias-s  → if Alias differs from ConnectName
foreach ($cl in $global:ONTAP_Clusters) {
    $connectName = $cl.ConnectName
    $sshHost     = if ($cl.FallbackIP) { $cl.FallbackIP } else { $cl.ConnectName }
    $alias       = $cl.Alias
    $csvPrefix   = $cl.CsvPrefix

    # --- Connect function: <ConnectName> → Connect-NcController <ConnectName> ---
    # Uses ConnectName (hostname) so Add-NcCredential lookups match by name.
    # Only clusters that truly need IP (no DNS) should leave ConnectName = FallbackIP in config.
    $connectBody = [scriptblock]::Create("Connect-NcController '$connectName'")
    Set-Item -Path "function:global:$connectName" -Value $connectBody

    # --- SSH function: <ConnectName>-s ---
    $sshFuncName = "$connectName-s"
    $sshBody = [scriptblock]::Create(@"
param([Parameter(Mandatory=`$false)][string]`$Command)
if (`$Command) { ssh admin@$sshHost `$Command } else { ssh admin@$sshHost }
"@)
    Set-Item -Path "function:global:$sshFuncName" -Value $sshBody

    # --- Alias → connect function (if Alias is set and differs from ConnectName) ---
    if ($alias -and $alias -ne $connectName) {
        Set-Alias -Name $alias   -Value $connectName  -Scope Global -Force -ErrorAction SilentlyContinue
        Set-Alias -Name "$alias-s" -Value $sshFuncName -Scope Global -Force -ErrorAction SilentlyContinue
    }

    # --- CSV wrapper: Get-<CsvPrefix>Csv ---
    if ($csvPrefix) {
        $csvFuncName = "Get-${csvPrefix}Csv"
        $csvBody = [scriptblock]::Create(@"
param([Parameter(Mandatory=`$true)][string]`$Command,[string[]]`$Headers)
Invoke-OntapCsv -SshFunction '$sshFuncName' -Command `$Command -Headers `$Headers
"@)
        Set-Item -Path "function:global:$csvFuncName" -Value $csvBody
    }
}


