<#
.SYNOPSIS
    One-time WSL setup for Ansible S3 bucket provisioning.
.DESCRIPTION
    Automates the WSL (Ubuntu-22.04) prerequisites for running Ansible
    playbooks from this workspace:

      1. Installs pip packages: ansible, netapp-lib
      2. Installs Ansible collection: netapp.ontap
      3. Optionally creates and encrypts a vault credentials file for a
         specific cluster (using vault_key from the credential store)

    Run this once per WSL environment. Safe to re-run — pip and
    ansible-galaxy handle already-installed packages gracefully.

.PARAMETER SetupVault
    After installing Ansible, also create and encrypt a vault credentials
    file for the cluster specified by -Cluster.

.PARAMETER Cluster
    Cluster alias from config.json. Required when -SetupVault is used.
    Reads the ONTAP password from credentials/<CredentialName>.cred
    (per S3_Config) and encrypts it into a vault file.

.PARAMETER SkipInstall
    Skip pip/collection install steps (use when Ansible is already installed
    and you only want to set up a vault file).

.PARAMETER WslDistro
    WSL distribution name. Default: Ubuntu-22.04.

.EXAMPLE
    # Install Ansible + collection only
    .\scripts\WSL\Setup-AnsibleWSL.ps1

    # Install + create vault file for a cluster
    .\scripts\WSL\Setup-AnsibleWSL.ps1 -SetupVault -Cluster MyCluster

    # Vault only (Ansible already installed)
    .\scripts\WSL\Setup-AnsibleWSL.ps1 -SetupVault -Cluster MyCluster -SkipInstall

.NOTES
    Requires:
      - WSL with Ubuntu-22.04 (or specify -WslDistro)
      - credentials\aes.key + relevant .cred files (for -SetupVault)
      - config.json with S3_Config entries (for -SetupVault)
#>
[CmdletBinding()]
param(
    [switch]$SetupVault,
    [string]$Cluster,
    [switch]$SkipInstall,
    [string]$WslDistro = "Ubuntu-22.04"
)

$ErrorActionPreference = 'Stop'
$workspaceRoot = (Resolve-Path "$PSScriptRoot\..\..").Path

# ── Step 1: Install Ansible + netapp-lib in WSL ─────────────────────────────
if (-not $SkipInstall) {
    Write-Host "`n[1/3] Installing Ansible and netapp-lib in WSL ($WslDistro)..." -ForegroundColor Cyan

    $installCmd = @(
        'export PATH=/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin'
        'pip install --user --upgrade pip 2>/dev/null'
        'pip install --user ansible netapp-lib'
        'echo "---"'
        'ansible --version | head -1'
    ) -join '; '

    & wsl -d $WslDistro -- bash --norc --noprofile -c $installCmd
    if ($LASTEXITCODE -ne 0) { throw "pip install failed (exit $LASTEXITCODE)" }

    Write-Host "[1/3] pip packages installed." -ForegroundColor Green

    Write-Host "`n[2/3] Installing netapp.ontap Ansible collection..." -ForegroundColor Cyan

    $collectionCmd = @(
        'export PATH=/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin'
        'ansible-galaxy collection install netapp.ontap --force'
    ) -join '; '

    & wsl -d $WslDistro -- bash --norc --noprofile -c $collectionCmd
    if ($LASTEXITCODE -ne 0) { throw "ansible-galaxy install failed (exit $LASTEXITCODE)" }

    Write-Host "[2/3] netapp.ontap collection installed." -ForegroundColor Green
} else {
    Write-Host "[1/3] Skipped pip install (-SkipInstall)" -ForegroundColor DarkGray
    Write-Host "[2/3] Skipped collection install (-SkipInstall)" -ForegroundColor DarkGray
}

# ── Step 3: Create + encrypt vault file ──────────────────────────────────────
if ($SetupVault) {
    if (-not $Cluster) {
        throw "-Cluster is required when using -SetupVault. Specify the cluster alias from config.json."
    }

    Write-Host "`n[3/3] Setting up vault credentials for cluster '$Cluster'..." -ForegroundColor Cyan

    # Load config.json
    $configPath = Join-Path $workspaceRoot 'config.json'
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "config.json not found. Run '. .\Load-Config.ps1' first."
    }
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json

    # Find S3_Config for this cluster
    $s3Cfg = $null
    $clusterObj = $config.ONTAP_Clusters | Where-Object {
        $_.ClusterName -eq $Cluster -or $_.ConnectName -eq $Cluster -or $_.Alias -eq $Cluster
    } | Select-Object -First 1

    if (-not $clusterObj) {
        $validNames = ($config.ONTAP_Clusters | ForEach-Object { $_.Alias }) -join ', '
        throw "Cluster '$Cluster' not found in config.json. Valid aliases: $validNames"
    }

    if ($config.S3_Config -and $config.S3_Config.Clusters) {
        foreach ($key in @($clusterObj.Alias, $clusterObj.ClusterName, $clusterObj.ConnectName)) {
            if ($config.S3_Config.Clusters.PSObject.Properties[$key]) {
                $s3Cfg = $config.S3_Config.Clusters.$key
                break
            }
        }
    }

    if (-not $s3Cfg) {
        throw "No S3_Config entry for '$Cluster' in config.json. Add it under S3_Config.Clusters."
    }

    $credName = $s3Cfg.CredentialName
    if (-not $credName) { $credName = "ontap_s3" }

    # Get ONTAP password from credential store
    $getCredScript = Join-Path $workspaceRoot "scripts\credentials\Get-Credential.ps1"
    $ontapPassword = & $getCredScript -Name $credName
    if ([string]::IsNullOrWhiteSpace($ontapPassword)) {
        throw "Credential '$credName' returned empty. Run: .\scripts\credentials\New-Credential.ps1 -Name '$credName'"
    }
    Write-Host "  ONTAP credential: $credName.cred" -ForegroundColor White

    # Get vault master key
    $vaultKey = & $getCredScript -Name "vault_key"
    if ([string]::IsNullOrWhiteSpace($vaultKey)) {
        throw "vault_key.cred returned empty. Run: .\scripts\credentials\New-Credential.ps1 -Name 'vault_key'"
    }
    Write-Host "  Vault key: vault_key.cred" -ForegroundColor White

    # Determine vault file name from S3_Config or generate one
    $vaultFileName = $s3Cfg.VaultFile
    if (-not $vaultFileName) {
        $safeAlias = ($clusterObj.Alias -replace '[^a-zA-Z0-9_-]', '_').ToLower()
        $vaultFileName = "vault_credentials_$safeAlias.yml"
    }
    $wsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $vaultFilePath = Join-Path $wsRoot "credentials" $vaultFileName

    # Write plaintext vault file
    $vaultContent = @"
# Vault-encrypted credentials for $($clusterObj.Alias) ($($clusterObj.Description))
# Encrypted by Setup-AnsibleWSL.ps1 — do not edit manually
ontap_password: "$($ontapPassword -replace '"', '\"')"
"@
    $vaultDir = Split-Path $vaultFilePath -Parent
    if (-not (Test-Path $vaultDir)) { New-Item -ItemType Directory -Path $vaultDir -Force | Out-Null }
    Set-Content -LiteralPath $vaultFilePath -Value $vaultContent -Encoding utf8NoBOM
    Write-Host "  Created: $vaultFileName" -ForegroundColor White

    # Encrypt with ansible-vault via WSL
    $wslVaultFile = $vaultFilePath -replace '\\', '/' -replace '^([A-Za-z]):', { "/mnt/$($_.Groups[1].Value.ToLower())" }

    # Write vault key to WSL /tmp/
    $vaultPassId      = [guid]::NewGuid().ToString('N').Substring(0,8)
    $wslVaultPassFile = "/tmp/_vault_pass_$vaultPassId.tmp"
    & wsl -d $WslDistro -- bash -c "echo -n '$($vaultKey -replace "'","'\''")' > $wslVaultPassFile && chmod 600 $wslVaultPassFile"

    $encryptCmd = "export PATH=/usr/local/bin:/usr/bin:/bin:`$HOME/.local/bin; ansible-vault encrypt '$wslVaultFile' --vault-password-file '$wslVaultPassFile'"
    & wsl -d $WslDistro -- bash --norc --noprofile -c $encryptCmd

    # Clean up temp vault pass
    & wsl -d $WslDistro -- rm -f $wslVaultPassFile 2>$null

    if ($LASTEXITCODE -ne 0) {
        throw "ansible-vault encrypt failed (exit $LASTEXITCODE)"
    }

    Write-Host "  Encrypted: $vaultFileName" -ForegroundColor Green
    Write-Host "[3/3] Vault file ready." -ForegroundColor Green
} else {
    Write-Host "`n[3/3] Skipped vault setup (use -SetupVault -Cluster <alias> to create one)" -ForegroundColor DarkGray
}

Write-Host "`nSetup complete. Test with:" -ForegroundColor Cyan
Write-Host "  .\ansible\s3-bucket-provision\Invoke-S3Provision.ps1 -Cluster <alias> -BucketName test-bucket -DryRun" -ForegroundColor White
