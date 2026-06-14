# Test ONTAP read-only credentials on all clusters
$rootDir = (Resolve-Path "$PSScriptRoot\..\..").Path
. "$rootDir\Load-Config.ps1"

$roUser = $config.ONTAP_Credential.JenkinsCredentialId
$cred = Get-Credential -UserName $roUser -Message "Enter $roUser password"

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
