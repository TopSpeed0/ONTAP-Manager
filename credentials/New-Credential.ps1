<#
.SYNOPSIS
    Create or update an encrypted credential file.
.DESCRIPTION
    Encrypts a password using AES-256 key and stores it as a file.
    Same pattern as HCI_Manager\New-AdminCredential.ps1.
    The AES key is auto-generated on first run.
.EXAMPLE
    .\New-Credential.ps1 -Name "ontap_s3"
    .\New-Credential.ps1 -Name "ontap_s3" -Force
#>
param(
    [Parameter(Mandatory)]
    [string]$Name,

    [switch]$Force
)

$credPath = $PSScriptRoot
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
