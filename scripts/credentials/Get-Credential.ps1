<#
.SYNOPSIS
    Retrieve a stored encrypted credential as plaintext or SecureString.
.DESCRIPTION
    Decrypts a .cred file using the shared AES key (credentials\aes.key).
    Returns plaintext by default (for piping to Ansible/CLI).
    Use -AsSecureString for PSCredential workflows.
    Throws if aes.key or the requested .cred file is missing.
.PARAMETER Name
    Name of the credential to retrieve. Looks for credentials\<Name>.cred.
.PARAMETER AsSecureString
    Return the password as a [SecureString] instead of plaintext.
    Useful when building a [PSCredential] object.
.OUTPUTS
    [string]       — plaintext password (default).
    [SecureString] — when -AsSecureString is specified.
.EXAMPLE
    # Plaintext (for Ansible vars_files or env vars)
    $pwd = & .\scripts\credentials\Get-Credential.ps1 -Name "ontap_s3"
.EXAMPLE
    # SecureString (for PSCredential)
    $sec = & .\scripts\credentials\Get-Credential.ps1 -Name "ontap_s3" -AsSecureString
.NOTES
    Requires New-Credential.ps1 to have been run at least once to generate
    aes.key and the target .cred file.
    Credential data is stored in credentials/ at the workspace root.
#>
param(
    [Parameter(Mandatory)]
    [string]$Name,

    [switch]$AsSecureString
)

$credPath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'credentials'
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
