<#
.SYNOPSIS
    Retrieve a stored encrypted credential as plaintext or SecureString.
.DESCRIPTION
    Decrypts a .cred file using the shared AES key.
    Returns plaintext by default (for piping to Ansible/CLI).
    Use -AsSecureString for PSCredential workflows.
.EXAMPLE
    # Plaintext (for Ansible vars_files or env vars)
    $pwd = .\Get-Credential.ps1 -Name "ontap_s3"

    # SecureString (for PSCredential)
    $sec = .\Get-Credential.ps1 -Name "ontap_s3" -AsSecureString
#>
param(
    [Parameter(Mandatory)]
    [string]$Name,

    [switch]$AsSecureString
)

$credPath = $PSScriptRoot
$keyFile  = Join-Path $credPath "aes.key"
$credFile = Join-Path $credPath "$Name.cred"

if (-not (Test-Path $keyFile))  { throw "AES key not found: $keyFile. Run New-Credential.ps1 first." }
if (-not (Test-Path $credFile)) { throw "Credential file not found: $credFile. Run New-Credential.ps1 -Name '$Name' first." }

$aesKey = Get-Content -Path $keyFile
$secure = Get-Content -Path $credFile | ConvertTo-SecureString -Key $aesKey

if ($AsSecureString) { return $secure }

# Return plaintext
$bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try {
    [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
} finally {
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}
