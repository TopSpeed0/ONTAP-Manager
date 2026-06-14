<#
.SYNOPSIS
    Test if /api/private/cli/vserver/config/override REST API works on a cluster.

.DESCRIPTION
    Sends a harmless command (vol show on a fake volume) to check if the endpoint exists.
    - If ONTAP returns a proper error ("volume not found") → endpoint works, we can automate via REST.
    - If we get HTTP 404 → endpoint doesn't exist, SSH is the only option.

.EXAMPLE
    .\Test-VserverConfigOverrideAPI.ps1 -ClusterName <cluster-name>
    .\Test-VserverConfigOverrideAPI.ps1 -ClusterName <cluster-name> -Credential (Get-Credential)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$ClusterName,
    [string]$Vserver = "svm_nas_K8s",
    [PSCredential]$Credential
)

$rootDir = (Resolve-Path "$PSScriptRoot\..\..").Path
. "$rootDir\Load-Config.ps1"

# Resolve cluster from config
$clEntry = $ONTAP_Clusters | Where-Object { $_.ClusterName -eq $ClusterName -or $_.ConnectName -eq $ClusterName }
if (-not $clEntry) {
    $available = ($ONTAP_Clusters | ForEach-Object { $_.ClusterName }) -join ', '
    throw "Unknown cluster '$ClusterName'. Available: $available"
}
$Cluster = if ($clEntry.FallbackIP) { $clEntry.FallbackIP } else { $clEntry.ConnectName }

# --- Get credentials ---
if (-not $Credential) {
    $Credential = Get-Credential -Message "Enter admin credentials for $Cluster"
}

# Skip SSL cert validation (self-signed certs)
if (-not ([System.Management.Automation.PSTypeName]'TrustAllCertsPolicy').Type) {
    Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
"@
}
[System.Net.ServicePointManager]::CertificatePolicy = [TrustAllCertsPolicy]::new()
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$baseUri = "https://$Cluster"
$headers = @{ "Content-Type" = "application/json" }

# --- Test 1: Check if the endpoint path exists ---
Write-Host "`n=== Test 1: Check endpoint /api/private/cli/vserver/config/override ===" -ForegroundColor Cyan
$testCommand = "vol show -vserver $Vserver -volume DOES_NOT_EXIST_TEST_12345 -fields volume"
$body = @{ command = $testCommand } | ConvertTo-Json

try {
    $response = Invoke-RestMethod `
        -Uri "$baseUri/api/private/cli/vserver/config/override" `
        -Method POST `
        -Headers $headers `
        -Body $body `
        -Credential $Credential `
        -ErrorAction Stop

    Write-Host "SUCCESS - Endpoint exists! Response:" -ForegroundColor Green
    $response | ConvertTo-Json -Depth 5
}
catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    $errorBody = ""
    if ($_.Exception.Response) {
        try {
            $stream = $_.Exception.Response.GetResponseStream()
            $reader = [System.IO.StreamReader]::new($stream)
            $errorBody = $reader.ReadToEnd()
            $reader.Close()
        } catch {}
    }

    if ($statusCode -eq 404) {
        Write-Host "RESULT: 404 - Endpoint does NOT exist. SSH is the only option." -ForegroundColor Red
    }
    elseif ($statusCode -eq 403 -or $statusCode -eq 401) {
        Write-Host "RESULT: $statusCode - Auth issue. Endpoint may exist but credentials lack diag privileges." -ForegroundColor Yellow
    }
    else {
        Write-Host "RESULT: HTTP $statusCode - Unexpected response (endpoint may exist)." -ForegroundColor Yellow
    }

    Write-Host "Error body: $errorBody" -ForegroundColor DarkGray
}

# --- Test 2: Check if generic /api/private/cli works at all ---
Write-Host "`n=== Test 2: Baseline - /api/private/cli/version (should always work) ===" -ForegroundColor Cyan
try {
    $versionResp = Invoke-RestMethod `
        -Uri "$baseUri/api/private/cli/version" `
        -Method GET `
        -Credential $Credential `
        -ErrorAction Stop

    Write-Host "SUCCESS - /api/private/cli is available. ONTAP version:" -ForegroundColor Green
    $versionResp | ConvertTo-Json -Depth 3
}
catch {
    $statusCode2 = $_.Exception.Response.StatusCode.value__
    Write-Host "RESULT: HTTP $statusCode2 - /api/private/cli may not be enabled on this cluster." -ForegroundColor Red
}

# --- Test 3: Try the documented /api/cluster endpoint as sanity check ---
Write-Host "`n=== Test 3: Sanity - /api/cluster (public REST API) ===" -ForegroundColor Cyan
try {
    $clusterResp = Invoke-RestMethod `
        -Uri "$baseUri/api/cluster" `
        -Method GET `
        -Credential $Credential `
        -ErrorAction Stop

    Write-Host "SUCCESS - REST API is reachable. Cluster: $($clusterResp.name), ONTAP: $($clusterResp.version.full)" -ForegroundColor Green
}
catch {
    Write-Host "FAILED - Cannot reach REST API at all. Check network/creds." -ForegroundColor Red
}

Write-Host "`n=== Tests complete ===" -ForegroundColor Cyan
