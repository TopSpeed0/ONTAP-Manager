# Update-ReadmeClusterTable.ps1
# Reads config.json and regenerates the cluster table in README.MD
# between the CLUSTER-TABLE:START and CLUSTER-TABLE:END markers.
# Run after adding/removing clusters in config.json.

param(
    [string]$ConfigPath = "$PSScriptRoot\config.json",
    [string]$ReadmePath = "$PSScriptRoot\README.MD"
)

if (-not (Test-Path $ConfigPath)) { throw "config.json not found at $ConfigPath" }
if (-not (Test-Path $ReadmePath)) { throw "README.MD not found at $ReadmePath" }

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

# Build table rows from config
$header = @(
    '## Clusters',
    '',
    '| Alias | Cluster | SSH Function | Connect Function | CSV Helper | Description |',
    '|-------|---------|--------------|------------------|------------|-------------|'
)

$rows = foreach ($cl in $config.ONTAP_Clusters) {
    $alias  = if ($cl.Alias) { $cl.Alias } else { $cl.ConnectName }
    $csv    = if ($cl.CsvPrefix) { "``Get-$($cl.CsvPrefix)Csv``" } else { '' }
    "| ``$alias`` | $($cl.ClusterName) | ``$alias-s`` | ``$alias`` | $csv | $($cl.Description) |"
}

$Block = @('<!-- CLUSTER-TABLE:START - Auto-generated from config.json by Update-ReadmeClusterTable.ps1. Do not edit manually. -->')
$Block += $header
$Block += $rows
$Block += '<!-- CLUSTER-TABLE:END -->'

# Replace content between markers
$readme = Get-Content $ReadmePath -Raw
$pattern = '(?s)<!-- CLUSTER-TABLE:START.*?-->.*?<!-- CLUSTER-TABLE:END -->'
if ($readme -notmatch $pattern) {
    throw "Could not find CLUSTER-TABLE markers in README.MD"
}

$updated = $readme -replace $pattern, ($Block -join "`n")
Set-Content $ReadmePath -Value $updated -NoNewline -Encoding UTF8

Write-Host "README.MD cluster table updated ($($config.ONTAP_Clusters.Count) clusters)" -ForegroundColor Green
