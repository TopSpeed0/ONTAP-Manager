<#
.SYNOPSIS
    Test ONTAP user credentials against all clusters defined in config.json.
.DESCRIPTION
    Connects to every cluster in $ONTAP_Clusters using Connect-NcController
    (DataONTAP PowerShell module / ZAPI) and reports success or failure.

    Password resolution order:
      1. Credential store — loads credentials/<UserName>.cred via Get-Credential.ps1 -AsSecureString
      2. Interactive prompt — falls back to Get-Credential if no .cred file exists

    Uses FallbackIP when defined in config.json, otherwise connects by ConnectName.
.PARAMETER UserName
    The ONTAP user name to test. Defaults to the ONTAP_ROUser value from config.json
    (e.g., "readonly_user"). If neither is provided, the script throws an error.
.EXAMPLE
    .\Test-NetappROUser.ps1
    # Tests the default read-only user (ONTAP_ROUser from config.json) against all clusters.
.EXAMPLE
    .\Test-NetappROUser.ps1 -UserName admin
    # Tests the "admin" user — prompts for password interactively if no admin.cred exists.
.NOTES
    Prerequisites:
      - DataONTAP PowerShell module (Connect-NcController)
      - config.json with ONTAP_Clusters and ONTAP_ROUser defined
      - credentials/aes.key + credentials/<UserName>.cred (optional — for unattended use)
#>
param(
    [string]$UserName
)
$rootDir = (Resolve-Path "$PSScriptRoot\..\..").Path
. "$rootDir\Load-Config.ps1"

if (-not $UserName) { $UserName = $Config.ONTAP_ROUser }
if (-not $UserName) { throw "No UserName provided and ONTAP_ROUser not set in config.json" }

# Try loading password from credential store, fall back to interactive prompt
$credFile = Join-Path $rootDir "credentials\$UserName.cred"
if (Test-Path $credFile) {
    $secPass = & "$rootDir\credentials\Get-Credential.ps1" -Name $UserName -AsSecureString
    $cred = New-Object System.Management.Automation.PSCredential($UserName, $secPass)
    Write-Host "Loaded credential from store: $UserName.cred" -ForegroundColor Green
} else {
    Write-Host "No credential file found ($UserName.cred) — prompting interactively" -ForegroundColor Yellow
    $cred = Get-Credential -UserName $UserName -Message "Enter $UserName password"
}

$results = foreach ($cl in $ONTAP_Clusters) {
    $addr = if ($cl.FallbackIP) { $cl.FallbackIP } else { $cl.ConnectName }
    try {
        $conn = Connect-NcController $addr -Credential $cred -ErrorAction Stop
        [PSCustomObject]@{
            Cluster = $cl.ClusterName
            Status  = "OK"
            Version = $conn.Version
            Name    = $conn.Name
        }
    }
    catch {
        [PSCustomObject]@{
            Cluster = $cl.ClusterName
            Status  = "FAILED"
            Version = "-"
            Name    = $_.Exception.Message
        }
    }
}

$results | Format-Table -AutoSize
