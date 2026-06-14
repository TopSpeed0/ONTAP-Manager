<#
.SYNOPSIS
    Provision an S3 bucket on any ONTAP cluster using config.json + credential store.
.DESCRIPTION
    PowerShell wrapper around provision_s3_bucket_generic.yml that automatically
    resolves cluster hostname, SVM, S3 user, credentials, and vault file from
    config.json (S3_Config section) and the workspace credential store.

    Two authentication modes:
      1. Direct (default): Pulls ONTAP password from credentials\<CredentialName>.cred
         and injects it into the playbook via a temp JSON extra-vars file.
      2. Vault (-UseVault): Pulls the vault master key from credentials\vault_key.cred,
         writes a temp vault-password file, and passes --vault-password-file + a
         vault credentials YAML to Ansible.

    When S3_Config.Clusters.<alias> exists in config.json, all connection details
    (Vserver, S3User, OntapUsername, CredentialName, VaultFile) are loaded
    automatically. You only need -Cluster and -BucketName.
.PARAMETER Cluster
    Cluster alias or name from config.json (e.g., <cluster-alias>).
    Must exist in both ONTAP_Clusters and S3_Config.Clusters.
.PARAMETER BucketName
    Name of the S3 bucket to create.
.PARAMETER Vserver
    SVM name. Auto-loaded from S3_Config if not specified.
.PARAMETER S3User
    S3 object user. Auto-loaded from S3_Config if not specified.
.PARAMETER CredentialName
    Name of .cred file. Auto-loaded from S3_Config if not specified.
.PARAMETER UseVault
    Use vault-based auth instead of direct credential injection.
.PARAMETER VaultFile
    Vault credentials YAML path (relative to playbook dir).
    Auto-loaded from S3_Config if not specified.
.PARAMETER OntapUsername
    ONTAP login user. Auto-loaded from S3_Config if not specified.
.PARAMETER BucketSize
    Bucket size in human-readable format. Default: "100GB".
.PARAMETER BucketComment
    Optional comment for the bucket.
.PARAMETER DryRun
    Show the ansible-playbook command without executing it.
.EXAMPLE
    # Minimal — everything from config.json
    .\Invoke-S3Provision.ps1 -Cluster <cluster-alias> -BucketName my-bucket

    # Another cluster — all details from config
    .\Invoke-S3Provision.ps1 -Cluster <cluster-alias> -BucketName data-lake

    # Vault mode
    .\Invoke-S3Provision.ps1 -Cluster <cluster-alias> -BucketName my-bucket -UseVault

    # Override S3 user
    .\Invoke-S3Provision.ps1 -Cluster <cluster-alias> -BucketName data-lake -S3User custom-user

    # Dry-run
    .\Invoke-S3Provision.ps1 -Cluster <cluster-alias> -BucketName test -DryRun
.NOTES
    Requires:
      - config.json with S3_Config.Clusters entries
      - credentials\aes.key + relevant .cred files
      - WSL Ubuntu-22.04 with ansible + netapp.ontap collection installed
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Cluster,

    [Parameter(Mandatory)]
    [string]$BucketName,

    [string]$Vserver,
    [string]$S3User,
    [string]$CredentialName,
    [switch]$UseVault,
    [string]$VaultFile,
    [string]$OntapUsername,
    [string]$BucketSize     = "100GB",
    [string]$BucketComment  = "Provisioned by Ansible automation",
    [switch]$DryRun
)

# --- Resolve workspace root ------------------------------------------------
$workspaceRoot = (Resolve-Path "$PSScriptRoot\..\..").Path

# --- Load config.json -------------------------------------------------------
$configPath = Join-Path $workspaceRoot 'config.json'
if (-not (Test-Path -LiteralPath $configPath)) {
    throw "config.json not found at $configPath. Run Load-Config.ps1 first."
}
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json

# --- Resolve cluster to hostname -------------------------------------------
$clusterObj = $config.ONTAP_Clusters | Where-Object {
    $_.ClusterName -eq $Cluster -or $_.ConnectName -eq $Cluster -or $_.Alias -eq $Cluster
} | Select-Object -First 1

if (-not $clusterObj) {
    $validNames = ($config.ONTAP_Clusters | ForEach-Object { "$($_.Alias) ($($_.ClusterName))" }) -join ', '
    throw "Cluster '$Cluster' not found in config.json. Valid: $validNames"
}

# Prefer FallbackIP (direct IP) over ClusterName (DNS) for reliability
$ontapHostname = if ($clusterObj.FallbackIP) { $clusterObj.FallbackIP } else { $clusterObj.ClusterName }
Write-Host "Cluster: $($clusterObj.Alias) → $ontapHostname ($($clusterObj.Description))" -ForegroundColor Cyan

# --- Resolve S3_Config defaults for this cluster ----------------------------
$s3Cfg = $null
if ($config.S3_Config -and $config.S3_Config.Clusters) {
    # Try Alias first, then ClusterName, then ConnectName
    foreach ($key in @($clusterObj.Alias, $clusterObj.ClusterName, $clusterObj.ConnectName)) {
        if ($config.S3_Config.Clusters.PSObject.Properties[$key]) {
            $s3Cfg = $config.S3_Config.Clusters.$key
            break
        }
    }
}

if ($s3Cfg) {
    Write-Host "S3 config: loaded from config.json (S3_Config.Clusters)" -ForegroundColor Cyan
    if (-not $Vserver)        { $Vserver        = $s3Cfg.Vserver }
    if (-not $S3User)         { $S3User         = $s3Cfg.S3User }
    if (-not $OntapUsername)   { $OntapUsername   = $s3Cfg.OntapUsername }
    if (-not $CredentialName)  { $CredentialName  = $s3Cfg.CredentialName }
    if (-not $VaultFile)      { $VaultFile       = $s3Cfg.VaultFile }
} else {
    Write-Host "S3 config: no S3_Config entry for '$Cluster' — using parameters" -ForegroundColor Yellow
}

# Final defaults for anything still empty
if (-not $OntapUsername)  { $OntapUsername  = "admin" }
if (-not $CredentialName) { $CredentialName = "ontap_s3" }

# Validate required fields
if (-not $Vserver) { throw "Vserver is required. Add it to S3_Config in config.json or pass -Vserver." }
if (-not $S3User)  { throw "S3User is required. Add it to S3_Config in config.json or pass -S3User." }

# --- Build WSL path ---------------------------------------------------------
# Convert Windows path to WSL /mnt/c/... path
$wslPlaybookDir = $PSScriptRoot -replace '\\', '/' -replace '^([A-Za-z]):', { "/mnt/$($_.Groups[1].Value.ToLower())" }

# --- Get ONTAP password from credential store --------------------------------
$getCredScript = Join-Path $workspaceRoot "credentials\Get-Credential.ps1"
if (-not (Test-Path -LiteralPath $getCredScript)) {
    throw "Get-Credential.ps1 not found at $getCredScript"
}

# Track temp files for cleanup
$tempFiles = @()
$cleanupWslVaultPass = $null

if ($UseVault) {
    # --- Vault mode: pull vault master key, write temp vault-pass file --------
    try {
        $vaultKey = & $getCredScript -Name "vault_key"
    } catch {
        throw "Failed to retrieve vault_key credential: $_"
    }
    if ([string]::IsNullOrWhiteSpace($vaultKey)) {
        throw "vault_key.cred returned empty password."
    }
    Write-Host "Vault key: vault_key.cred ✓" -ForegroundColor Cyan

    # Write vault key to WSL /tmp/ (avoids Windows NTFS execute-bit issue)
    $vaultPassId      = [guid]::NewGuid().ToString('N').Substring(0,8)
    $wslVaultPassFile = "/tmp/_vault_pass_$vaultPassId.tmp"
    wsl -d Ubuntu-22.04 -- bash -c "echo -n '$($vaultKey -replace "'","'\''")' > $wslVaultPassFile && chmod 600 $wslVaultPassFile"
    # Track for cleanup (WSL path)
    $cleanupWslVaultPass = $wslVaultPassFile

    # Verify vault file exists
    $vaultFilePath = Join-Path $PSScriptRoot $VaultFile
    if (-not (Test-Path -LiteralPath $vaultFilePath)) {
        throw "Vault file not found: $vaultFilePath"
    }
    Write-Host "Vault file: $VaultFile ✓" -ForegroundColor Cyan

    # Build extra vars (no password — it comes from the vault file)
    $tempFile    = Join-Path $PSScriptRoot "_provision_vars.json"
    $wslTempFile = "$wslPlaybookDir/_provision_vars.json"
    $tempFiles += $tempFile

    $varsObj = [ordered]@{
        ontap_hostname = $ontapHostname
        ontap_vserver  = $Vserver
        ontap_username = $OntapUsername
        bucket_name    = $BucketName
        s3_user        = $S3User
        bucket_size    = $BucketSize
        bucket_comment = $BucketComment
    }
    $varsObj | ConvertTo-Json | Set-Content -LiteralPath $tempFile -Encoding utf8NoBOM

    # Build WSL command with vault
    $wslArgs = @('-d', 'Ubuntu-22.04', '--', 'bash', '--norc', '--noprofile', '-c',
        "export PATH=/usr/local/bin:/usr/bin:/bin:`$HOME/.local/bin; cd '$wslPlaybookDir'; ansible-playbook provision_s3_bucket_generic.yml -e '@$wslTempFile' -e '@$wslPlaybookDir/$VaultFile' --vault-password-file '$wslVaultPassFile'")
    $authMode = "vault ($VaultFile)"

} else {
    # --- Direct mode: pull ONTAP password, write temp JSON vars file ----------
    try {
        $ontapPassword = & $getCredScript -Name $CredentialName
    } catch {
        throw "Failed to retrieve credential '$CredentialName': $_"
    }
    if ([string]::IsNullOrWhiteSpace($ontapPassword)) {
        throw "Credential '$CredentialName' returned empty password."
    }
    Write-Host "Credential: $CredentialName.cred ✓" -ForegroundColor Cyan

    # Write extra vars to temp JSON file (avoids all shell quoting issues)
    $tempFile    = Join-Path $PSScriptRoot "_provision_vars.json"
    $wslTempFile = "$wslPlaybookDir/_provision_vars.json"
    $tempFiles += $tempFile

    $varsObj = [ordered]@{
        ontap_hostname = $ontapHostname
        ontap_vserver  = $Vserver
        ontap_username = $OntapUsername
        ontap_password = $ontapPassword
        bucket_name    = $BucketName
        s3_user        = $S3User
        bucket_size    = $BucketSize
        bucket_comment = $BucketComment
    }
    $varsObj | ConvertTo-Json | Set-Content -LiteralPath $tempFile -Encoding utf8NoBOM

    # Build WSL command (matching the proven README pattern)
    $wslArgs = @('-d', 'Ubuntu-22.04', '--', 'bash', '--norc', '--noprofile', '-c',
        "export PATH=/usr/local/bin:/usr/bin:/bin:`$HOME/.local/bin; cd '$wslPlaybookDir'; ansible-playbook provision_s3_bucket_generic.yml -e '@$wslTempFile'")
    $authMode = "direct ($CredentialName.cred)"
}

# --- Execute or dry-run -----------------------------------------------------
Write-Host ""
Write-Host "Target:     $ontapHostname / $Vserver" -ForegroundColor White
Write-Host "Bucket:     $BucketName ($BucketSize)" -ForegroundColor White
Write-Host "S3 User:    $S3User" -ForegroundColor White
Write-Host "ONTAP User: $OntapUsername" -ForegroundColor White
Write-Host "Auth:       $authMode" -ForegroundColor White
Write-Host ""

if ($DryRun) {
    Write-Host "DRY RUN — would execute:" -ForegroundColor Yellow
    $displayCmd = "wsl $($wslArgs -join ' ')"
    $safeCmd = $displayCmd -replace [regex]::Escape($wslTempFile), '<extra-vars.json>'
    if ($UseVault) { $safeCmd = $safeCmd -replace [regex]::Escape($wslVaultPassFile), '<vault-pass.tmp>' }
    Write-Host $safeCmd -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Extra vars:" -ForegroundColor DarkGray
    $safeVars = [ordered]@{}
    foreach ($key in $varsObj.Keys) {
        $safeVars[$key] = if ($key -eq 'ontap_password') { '********' } else { $varsObj[$key] }
    }
    Write-Host ($safeVars | ConvertTo-Json) -ForegroundColor DarkGray
    # Clean up temp files even in dry-run
    foreach ($f in $tempFiles) { Remove-Item -LiteralPath $f -ErrorAction SilentlyContinue }
    if ($cleanupWslVaultPass) { wsl -d Ubuntu-22.04 -- rm -f $cleanupWslVaultPass 2>$null }
    return
}

Write-Host "Running ansible-playbook via WSL..." -ForegroundColor Green
try {
    & wsl @wslArgs
} finally {
    # Always clean up temp files (contain password / vault key)
    foreach ($f in $tempFiles) { Remove-Item -LiteralPath $f -ErrorAction SilentlyContinue }
    if ($cleanupWslVaultPass) { wsl -d Ubuntu-22.04 -- rm -f $cleanupWslVaultPass 2>$null }
}
