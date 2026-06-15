<#
.SYNOPSIS
    Create or update an encrypted credential file.
.DESCRIPTION
    Encrypts a password using AES-256 key and stores it as a .cred file.
    Same pattern as HCI_Manager\New-AdminCredential.ps1.
    The AES key (credentials\aes.key) is auto-generated on first run.
    If the target .cred file already exists, prompts for confirmation
    unless -Force is specified.
.PARAMETER Name
    Name for the credential. Saved as <Name>.cred in the credentials folder.
.PARAMETER Force
    Overwrite an existing .cred file without prompting for confirmation.
.EXAMPLE
    .\scripts\credentials\New-Credential.ps1 -Name "ontap_s3"
    # Prompts for password interactively and saves credentials\ontap_s3.cred.
.EXAMPLE
    .\scripts\credentials\New-Credential.ps1 -Name "ontap_s3" -Force
    # Overwrites ontap_s3.cred without asking.
.NOTES
    Files produced:
      credentials\aes.key   — shared AES-256 key (created once, reused)
      credentials\<Name>.cred — encrypted password file
    Both are excluded from git via credentials\.gitignore.
    Retrieve stored passwords with Get-Credential.ps1.
    Credential data is stored in credentials/ at the workspace root.
#>
param(
    [Parameter(Mandatory)]
    [string]$Name,

    [switch]$Force
)

$credPath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'credentials'
$keyFile  = Join-Path $credPath "aes.key"

# --- Generate AES key if missing ---
if (-not (Test-Path $keyFile)) {
    Write-Host "  Generating new AES-256 key: $keyFile" -ForegroundColor Yellow
    $aesKey = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($aesKey)
    $aesKey | Set-Content -Path $keyFile -Force
    Write-Host "  AES key created." -ForegroundColor Green
}

$aesKey  = Get-Content -Path $keyFile
$outFile = Join-Path $credPath "$Name.cred"

if ((Test-Path $outFile) -and -not $Force) {
    $overwrite = Read-Host "  '$Name.cred' already exists. Overwrite? (y/N)"
    if ($overwrite -ne 'y') { return }
}

Write-Host "`n  Enter password for '$Name':" -ForegroundColor Yellow
$secPwd    = Read-Host -Prompt "  Password" -AsSecureString
$encrypted = $secPwd | ConvertFrom-SecureString -Key $aesKey
$encrypted | Set-Content -Path $outFile -Force
Write-Host "  Saved: $outFile" -ForegroundColor Green
