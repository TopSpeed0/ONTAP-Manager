# Get-BiggestSnapshot.ps1 - Find the biggest snapshots across all clusters
# Uses Load-Config.ps1 for cluster definitions.

$rootDir = (Resolve-Path "$PSScriptRoot\..\..").Path
. "$rootDir\Load-Config.ps1"

function Convert-OntapSize {
    param([string]$Size)
    if ([string]::IsNullOrWhiteSpace($Size)) { return 0 }
    $Size = $Size.Trim()
    switch -Regex ($Size) {
        '([\d.]+)TB' { return [double]$Matches[1] * 1TB }
        '([\d.]+)GB' { return [double]$Matches[1] * 1GB }
        '([\d.]+)MB' { return [double]$Matches[1] * 1MB }
        '([\d.]+)KB' { return [double]$Matches[1] * 1KB }
        '([\d.]+)B'  { return [double]$Matches[1] }
        default { return 0 }
    }
}

function Get-ClusterSnapshots {
    param(
        [string]$SshHost,
        [string]$ClusterName
    )
    Write-Host "  Querying $ClusterName via admin@$SshHost ..." -ForegroundColor Cyan
    try {
        $raw = ssh "admin@$SshHost" 'set -privilege diagnostic -confirmations off; rows 0; set -showseparator ","; vol snapshot show -fields vserver,volume,snapshot,size'
        if (-not $raw) {
            Write-Host "  WARNING: No output from $ClusterName" -ForegroundColor Yellow
            return @()
        }
        # Filter to CSV data lines: must contain comma, skip banners
        $csvLines = $raw | Where-Object {
            $_ -match ',' -and
            $_ -notmatch 'Last login' -and
            $_ -notmatch 'entries were displayed' -and
            $_ -notmatch 'WARNING' -and
            $_ -notmatch '^\s*$'
        } | ForEach-Object { $_.TrimEnd(',').Trim() }  # Remove trailing comma

        if ($csvLines.Count -lt 3) {
            Write-Host "  WARNING: Not enough data from $ClusterName (lines: $($csvLines.Count))" -ForegroundColor Yellow
            return @()
        }

        # Skip first line (field names like vserver,volume,snapshot,size)
        # Use second line as header (Vserver,Volume,Snapshot,Snapshot Size)
        $header = $csvLines[1]
        $dataLines = $csvLines[2..($csvLines.Count - 1)]

        $csvText = @($header) + $dataLines
        $objs = $csvText | ConvertFrom-Csv
        $objs | ForEach-Object { $_ | Add-Member -NotePropertyName Cluster -NotePropertyValue $ClusterName -Force }
        Write-Host "  $ClusterName : $($objs.Count) snapshots" -ForegroundColor Green
        return $objs
    } catch {
        Write-Host "  ERROR querying $ClusterName : $_ " -ForegroundColor Red
        return @()
    }
}

$allResults = @()

# Cluster definitions — loaded from config.json via Load-Config.ps1
foreach ($cl in $ONTAP_Clusters) {
    $sshHost = if ($cl.FallbackIP) { $cl.FallbackIP } else { $cl.ConnectName }
    $data = Get-ClusterSnapshots -SshHost $sshHost -ClusterName $cl.ClusterName
    if ($data) { $allResults += $data }
}

Write-Host "`n=== Total snapshots collected: $($allResults.Count) ===" -ForegroundColor White

# Sort by size (convert to bytes for proper numeric sorting)
$sorted = $allResults | Sort-Object { Convert-OntapSize $_.'Snapshot Size' } -Descending

# Top 20 biggest snapshots
Write-Host "`n=== TOP 20 BIGGEST SNAPSHOTS ACROSS ALL CLUSTERS ===" -ForegroundColor Yellow
$top20 = $sorted | Select-Object -First 20

# Build report
$report = @()
$rank = 0
foreach ($s in $top20) {
    $rank++
    $report += [PSCustomObject]@{
        Rank     = $rank
        Cluster  = $s.Cluster
        SVM      = $s.Vserver
        Volume   = $s.Volume
        Snapshot = $s.Snapshot
        Size     = $s.'Snapshot Size'
    }
}
$report | Format-Table -AutoSize

# Save to CSV for reference
$csvPath = "C:\Users\Operator\OneDrive\Documents\code\Netapp-Code-WorkSpace\biggest-snapshots.csv"
$report | Export-Csv -Path $csvPath -NoTypeInformation
Write-Host "`nResults saved to: $csvPath" -ForegroundColor Green
