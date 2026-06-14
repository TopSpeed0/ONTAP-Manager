# Test Netapp_RO_jack credentials on all clusters
$rootDir = (Resolve-Path "$PSScriptRoot\..\..").Path
. "$rootDir\Load-Config.ps1"

$cred = Get-Credential -UserName "Netapp_RO_jack" -Message "Enter Netapp_RO_jack password"

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
