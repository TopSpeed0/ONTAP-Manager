<#
.SYNOPSIS
    Create or update an encrypted credential file.
.DESCRIPTION
    Encrypts a password using AES-256 key and stores it as a .cred file.
    Same pattern as HCI_Manager\New-AdminCredential.ps1.
    The AES key (credentials\aes.key) is auto-generated on first run.
    If the target .cred file already exists, prompts for confirmation
    unless -Force is specified.
    When -UserName is provided, the mapping is saved in credentials\credentials.json
    so that consumers can resolve the username from the credential name alone.
.PARAMETER Name
    Name for the credential. Saved as <Name>.cred in the credentials folder.
.PARAMETER UserName
    Optional username (UPN, domain\user, or plain name) associated with this credential.
    Stored in credentials\credentials.json for lookup by Get-Credential.ps1 -IncludeUserName.
.PARAMETER Force
    Overwrite an existing .cred file without prompting for confirmation.
.EXAMPLE
    .\scripts\credentials\New-Credential.ps1 -Name "ontap_s3"
    # Prompts for password interactively and saves credentials\ontap_s3.cred.
.EXAMPLE
    .\scripts\credentials\New-Credential.ps1 -Name "example_admin" -UserName "admin@example.invalid"
    # Saves the credential AND registers the username in credentials.json.
.EXAMPLE
    .\scripts\credentials\New-Credential.ps1 -Name "ontap_s3" -Force
    # Overwrites ontap_s3.cred without asking.
.NOTES
    Files produced:
      credentials\aes.key          — shared AES-256 key (created once, reused)
      credentials\<Name>.cred      — encrypted password file
      credentials\credentials.json — credential-to-username registry (append/update)
    Both aes.key and *.cred are excluded from git via credentials\.gitignore.
    Retrieve stored passwords with Get-Credential.ps1.
    Credential data is stored in credentials/ at the workspace root.
#>
param(
    [Parameter(Mandatory)]
    [string]$Name,

    [string]$UserName,

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

# --- Update credentials.json registry ---
if ($UserName) {
    $registryFile = Join-Path $credPath 'credentials.json'
    $registry = @{}
    if (Test-Path -LiteralPath $registryFile) {
        $existing = Get-Content -LiteralPath $registryFile -Raw | ConvertFrom-Json
        foreach ($prop in $existing.PSObject.Properties) {
            $registry[$prop.Name] = $prop.Value
        }
    }
    $registry[$Name] = [pscustomobject]@{ UserName = $UserName }
    # Sort keys for consistent output
    $sorted = [ordered]@{}
    $registry.GetEnumerator() | Sort-Object Key | ForEach-Object { $sorted[$_.Key] = $_.Value }
    $sorted | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $registryFile -Encoding utf8
    Write-Host "  Registry updated: $Name → $UserName" -ForegroundColor Green
}
