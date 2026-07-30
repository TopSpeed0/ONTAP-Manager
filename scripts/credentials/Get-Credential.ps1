<#
.SYNOPSIS
    Retrieve a stored encrypted credential as plaintext or SecureString.
.DESCRIPTION
    Decrypts a .cred file using the shared AES key (credentials\aes.key).
    Returns plaintext by default (for piping to Ansible/CLI).
    Use -AsSecureString for PSCredential workflows.
    Use -IncludeUserName to also return the registered username from credentials.json.
    Throws if aes.key or the requested .cred file is missing.
.PARAMETER Name
    Name of the credential to retrieve. Looks for credentials\<Name>.cred.
.PARAMETER AsSecureString
    Return the password as a [SecureString] instead of plaintext.
    Useful when building a [PSCredential] object.
.PARAMETER IncludeUserName
    Return a hashtable with UserName and Password (or SecurePassword) instead of
    just the password string. The UserName is read from credentials\credentials.json.
    If no registry entry exists, UserName is $null.
.PARAMETER AsPSCredential
    Return a [PSCredential] object built from the registered username and stored password.
    Requires a matching entry in credentials\credentials.json for the username.
    Falls back to the -Name value as username if not registered.
.OUTPUTS
    [string]       — plaintext password (default).
    [SecureString] — when -AsSecureString is specified.
    [hashtable]    — when -IncludeUserName is specified: @{ Name; UserName; Password/SecurePassword }.
    [PSCredential] — when -AsPSCredential is specified.
.EXAMPLE
    # Plaintext (for Ansible vars_files or env vars)
    $pwd = & .\scripts\credentials\Get-Credential.ps1 -Name "ontap_s3"
.EXAMPLE
    # SecureString (for PSCredential)
    $sec = & .\scripts\credentials\Get-Credential.ps1 -Name "ontap_s3" -AsSecureString
.EXAMPLE
    # Get username + password together
    $cred = & .\scripts\credentials\Get-Credential.ps1 -Name "example_admin" -IncludeUserName
    # $cred.UserName = "admin@example.invalid", $cred.Password = "<plaintext>"
.EXAMPLE
    # Get a ready-to-use PSCredential object
    $psCred = & .\scripts\credentials\Get-Credential.ps1 -Name "example_admin" -AsPSCredential
.NOTES
    Requires New-Credential.ps1 to have been run at least once to generate
    aes.key and the target .cred file.
    Credential data is stored in credentials/ at the workspace root.
#>
param(
    [Parameter(Mandatory)]
    [string]$Name,

    [switch]$AsSecureString,
    [switch]$IncludeUserName,
    [switch]$AsPSCredential
)

$credPath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'credentials'
$keyFile  = Join-Path $credPath "aes.key"
$credFile = Join-Path $credPath "$Name.cred"

if (-not (Test-Path $keyFile))  { throw "AES key not found: $keyFile. Run New-Credential.ps1 first." }
if (-not (Test-Path $credFile)) { throw "Credential file not found: $credFile. Run New-Credential.ps1 -Name '$Name' first." }

$aesKey = Get-Content -Path $keyFile
$secure = Get-Content -Path $credFile | ConvertTo-SecureString -Key $aesKey

# --- Resolve username from registry ---
$registeredUserName = $null
if ($IncludeUserName -or $AsPSCredential) {
    $registryFile = Join-Path $credPath 'credentials.json'
    if (Test-Path -LiteralPath $registryFile) {
        $registry = Get-Content -LiteralPath $registryFile -Raw | ConvertFrom-Json
        if ($registry.PSObject.Properties.Name -contains $Name) {
            $registeredUserName = $registry.$Name.UserName
        }
    }
}

if ($AsPSCredential) {
    $userName = if ($registeredUserName) { $registeredUserName } else { $Name }
    return [pscredential]::new($userName, $secure)
}

if ($IncludeUserName) {
    if ($AsSecureString) {
        return @{ Name = $Name; UserName = $registeredUserName; SecurePassword = $secure }
    }
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    return @{ Name = $Name; UserName = $registeredUserName; Password = $plain }
}

if ($AsSecureString) { return $secure }

# Return plaintext
$bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try {
    [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
} finally {
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}
