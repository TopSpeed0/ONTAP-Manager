param(
    [string]$OutputPath = ".\NI_Colo_Volumes_DR_Status.csv"
)

# Load cluster config
$rootDir = (Resolve-Path "$PSScriptRoot\..\..").Path
. "$rootDir\Load-Config.ps1"

# Helper: resolve SSH host from config by cluster name
function Resolve-SshHost ([string]$Name) {
    $entry = $ONTAP_Clusters | Where-Object { $_.ClusterName -eq $Name -or $_.ConnectName -eq $Name }
    if (-not $entry) { throw "Cluster '$Name' not found in config.json" }
    if ($entry.FallbackIP) { $entry.FallbackIP } else { $entry.ConnectName }
}

$cl1Host   = Resolve-SshHost 'cluster-colo1'
$cl2Host   = Resolve-SshHost 'cluster-colo2'
$NidrHost  = Resolve-SshHost 'cluster-Nidr'
$cisvmHost = Resolve-SshHost 'legacy'

# ============================================================
# Step 1: Get all volumes from both clusters via SSH
# ============================================================
Write-Host "Collecting volumes from cluster-colo1..." -ForegroundColor Cyan
$cl1Raw = ssh "admin@$cl1Host" "set -rows 0; set -units GB; vol show -fields vserver,volume,size,used,aggregate,junction-path,state,vserver-dr-protection,type"
$cl1Lines = $cl1Raw | Where-Object { $_ -match '^\S+\s+\S+' -and $_ -notmatch '^(vserver|------|Vserver|\s|$|Access|Last|Warning|Note|set )' -and $_ -notmatch 'entries were displayed' }

Write-Host "Collecting volumes from cluster-colo2..." -ForegroundColor Cyan
$cl2Raw = ssh "admin@$cl2Host" "set -rows 0; set -units GB; vol show -fields vserver,volume,size,used,aggregate,junction-path,state,vserver-dr-protection,type"
$cl2Lines = $cl2Raw | Where-Object { $_ -match '^\S+\s+\S+' -and $_ -notmatch '^(vserver|------|Vserver|\s|$|Access|Last|Warning|Note|set )' -and $_ -notmatch 'entries were displayed' }

Write-Host "  cluster-colo1 volume lines: $($cl1Lines.Count)" -ForegroundColor Green
Write-Host "  cluster-colo2 volume lines: $($cl2Lines.Count)" -ForegroundColor Green

# Parse volume lines - field order: vserver, volume, aggregate, size, state, junction-path, used, type, vserver-dr-protection
function Parse-VolLine {
    param([string]$Line, [string]$Cluster)
    $parts = $Line -split '\s+' | Where-Object { $_ -ne '' }
    if ($parts.Count -ge 8) {
        [PSCustomObject]@{
            Source_Cluster = $Cluster
            Source_SVM     = $parts[0]
            Volume         = $parts[1]
            Aggregate      = $parts[2]
            Size           = $parts[3]
            State          = $parts[4]
            Junction_Path  = $parts[5]
            Used           = $parts[6]
            Type           = $parts[7]
            VserverDR      = if ($parts.Count -ge 9) { $parts[8] } else { '-' }
        }
    }
}

$allVols = @()
foreach ($line in $cl1Lines) { $v = Parse-VolLine -Line $line -Cluster 'cluster-colo1'; if ($v) { $allVols += $v } }
foreach ($line in $cl2Lines) { $v = Parse-VolLine -Line $line -Cluster 'cluster-colo2'; if ($v) { $allVols += $v } }
Write-Host "Total volumes parsed: $($allVols.Count)" -ForegroundColor Green

# ============================================================
# Step 2: Get SnapMirror list-destinations from BOTH source clusters (active mirrors)
# ============================================================
Write-Host "Collecting snapmirror list-destinations from cluster-colo1..." -ForegroundColor Cyan
$sm1Raw = ssh "admin@$cl1Host" "set -rows 0; snapmirror list-destinations -fields source-path,source-volume,source-vserver,destination-path,destination-volume,destination-vserver,type,policy-type,status"
$sm1Lines = $sm1Raw | Where-Object { $_ -match '^\S+:\S+\s+' -and $_ -notmatch '^(source|------|Vserver|\s|$|Access|Last|Warning|Note|set )' -and $_ -notmatch 'entries were displayed' }

Write-Host "Collecting snapmirror list-destinations from cluster-colo2..." -ForegroundColor Cyan
$sm2Raw = ssh "admin@$cl2Host" "set -rows 0; snapmirror list-destinations -fields source-path,source-volume,source-vserver,destination-path,destination-volume,destination-vserver,type,policy-type,status"
$sm2Lines = $sm2Raw | Where-Object { $_ -match '^\S+:\S+\s+' -and $_ -notmatch '^(source|------|Vserver|\s|$|Access|Last|Warning|Note|set )' -and $_ -notmatch 'entries were displayed' }

Write-Host "  cl1 list-destinations lines: $($sm1Lines.Count)" -ForegroundColor Green
Write-Host "  cl2 list-destinations lines: $($sm2Lines.Count)" -ForegroundColor Green

# ============================================================
# Step 3: Get snapmirror show from BOTH destination clusters
# ============================================================
Write-Host "Collecting snapmirror show from cluster-Nidr..." -ForegroundColor Cyan
$NidrRaw = ssh "admin@$NidrHost" "set -rows 0; snapmirror show -fields source-path,destination-path,state,status,policy,healthy,lag-time" 2>$null
$NidrLines = $NidrRaw | Where-Object { $_ -match '^\S+:\S+\s+' -and $_ -notmatch '^(source|------|Vserver|\s|$|Access|Last|Warning|Note|set )' -and $_ -notmatch 'entries were displayed' }

Write-Host "Collecting snapmirror show from legacy..." -ForegroundColor Cyan
$cisvmRaw = ssh "admin@$cisvmHost" "set -rows 0; snapmirror show -fields source-path,destination-path,state,status,policy,healthy,lag-time"
$cisvmLines = $cisvmRaw | Where-Object { $_ -match '^\S+:\S+\s+' -and $_ -notmatch '^(source|------|Vserver|\s|$|Access|Last|Warning|Note|set )' -and $_ -notmatch 'entries were displayed' }

Write-Host "  cluster-Nidr snapmirror entries: $($NidrLines.Count)" -ForegroundColor Green
Write-Host "  legacy snapmirror entries: $($cisvmLines.Count)" -ForegroundColor Green

# ============================================================
# Step 4: Build SnapMirror lookup from list-destinations (source side)
# ============================================================
$smDestinations = @{}
$allSmLines = @($sm1Lines) + @($sm2Lines)
foreach ($line in $allSmLines) {
    $parts = $line -split '\s+' | Where-Object { $_ -ne '' }
    # Fields: source-path, source-vserver, source-volume, destination-path, destination-vserver, destination-volume, type, policy-type, status
    if ($parts.Count -ge 9) {
        $srcSvm = $parts[1]
        $srcVol = $parts[2]
        $dstSvm = $parts[4]
        $dstVol = $parts[5]
        $policyType = $parts[7]
        $status = $parts[8]

        $dstCluster = switch ($dstSvm) {
            'svm_snapmirror_dr'     { 'cluster-Nidr' }
            'svm_snapmirror_backup' { 'legacy' }
            default             { 'unknown' }
        }

        $key = "${srcSvm}:${srcVol}"
        if (-not $smDestinations.ContainsKey($key)) { $smDestinations[$key] = @() }
        $smDestinations[$key] += [PSCustomObject]@{
            DestCluster = $dstCluster; DestSVM = $dstSvm; DestVolume = $dstVol
            PolicyType = $policyType; Status = $status; State = ''; Healthy = ''
        }
    }
}

# ============================================================
# Step 5: Build health/state lookup from destination-side snapmirror show
# ============================================================
function Parse-SmShowLine {
    param([string]$Line)
    # Actual field order: source-path, destination-path, policy, state, status, healthy, lag-time
    $parts = $Line -split '\s+' | Where-Object { $_ -ne '' }
    if ($parts.Count -ge 6) {
        [PSCustomObject]@{
            SourcePath = $parts[0]; DestPath = $parts[1]
            Policy = $parts[2]; State = $parts[3]
            Status = $parts[4]; Healthy = $parts[5]
            LagTime = if ($parts.Count -ge 7) { $parts[6] } else { '' }
        }
    }
}

# Nidr destination health keyed by "source-path|dest-path"
$NidrHealth = @{}
foreach ($line in $NidrLines) {
    $sm = Parse-SmShowLine -Line $line
    if ($sm) { $NidrHealth["$($sm.SourcePath)|$($sm.DestPath)"] = $sm }
}

# legacy destination health — also captures broken-off mirrors not in list-destinations
$cisvmHealth = @{}
foreach ($line in $cisvmLines) {
    $sm = Parse-SmShowLine -Line $line
    if ($sm) {
        $cisvmHealth["$($sm.SourcePath)|$($sm.DestPath)"] = $sm

        # Add broken-off (or any) relationships from legacy that may not appear in list-destinations
        $key = $sm.SourcePath
        $dstParts = $sm.DestPath -split ':'
        $dstSvm = $dstParts[0]
        $dstVol = if ($dstParts.Count -ge 2) { $dstParts[1] } else { '' }

        if (-not $smDestinations.ContainsKey($key)) { $smDestinations[$key] = @() }
        $exists = $smDestinations[$key] | Where-Object { $_.DestVolume -eq $dstVol -and $_.DestSVM -eq $dstSvm }
        if (-not $exists) {
            $smDestinations[$key] += [PSCustomObject]@{
                DestCluster = 'legacy'; DestSVM = $dstSvm; DestVolume = $dstVol
                PolicyType = $sm.Policy; Status = $sm.Status; State = $sm.State; Healthy = $sm.Healthy
            }
        }
    }
}

Write-Host "SnapMirror source volumes with destinations: $($smDestinations.Keys.Count)" -ForegroundColor Green

# ============================================================
# Step 6: Enrich list-destinations entries with health info from destination clusters
# ============================================================
foreach ($key in @($smDestinations.Keys)) {
    for ($i = 0; $i -lt $smDestinations[$key].Count; $i++) {
        $dest = $smDestinations[$key][$i]
        $lookupKey = "${key}|$($dest.DestSVM):$($dest.DestVolume)"

        if ($dest.DestCluster -eq 'cluster-Nidr' -and $NidrHealth.ContainsKey($lookupKey)) {
            $dest.Healthy = $NidrHealth[$lookupKey].Healthy
            $dest.State   = $NidrHealth[$lookupKey].State
        }
        if ($dest.DestCluster -eq 'legacy' -and $cisvmHealth.ContainsKey($lookupKey)) {
            $dest.Healthy = $cisvmHealth[$lookupKey].Healthy
            $dest.State   = $cisvmHealth[$lookupKey].State
        }
    }
}

# ============================================================
# Step 7: Build CSV — support up to 3 DR destinations per volume
# ============================================================
$csvRows = @()
foreach ($vol in $allVols) {
    $key = "$($vol.Source_SVM):$($vol.Volume)"
    $dests = $smDestinations[$key]

    $hasSM = if ($dests -and $dests.Count -gt 0) { 'Yes' } else { 'No' }
    $hasSvmDR = if ($vol.VserverDR -and $vol.VserverDR -ne '-') { $vol.VserverDR } else { 'No' }

    # Sort: cluster-Nidr first, then legacy, then others
    $sorted = @()
    if ($dests) {
        $sorted += $dests | Where-Object { $_.DestCluster -eq 'cluster-Nidr' }
        $sorted += $dests | Where-Object { $_.DestCluster -eq 'legacy' }
        $sorted += $dests | Where-Object { $_.DestCluster -notin @('cluster-Nidr','legacy') }
    }

    $d1 = if ($sorted.Count -ge 1) { $sorted[0] } else { $null }
    $d2 = if ($sorted.Count -ge 2) { $sorted[1] } else { $null }
    $d3 = if ($sorted.Count -ge 3) { $sorted[2] } else { $null }

    $row = [PSCustomObject]@{
        Source_Cluster     = $vol.Source_Cluster
        Source_SVM         = $vol.Source_SVM
        Source_Volume      = $vol.Volume
        Size               = $vol.Size
        Used               = $vol.Used
        Aggregate          = $vol.Aggregate
        Junction_Path      = $vol.Junction_Path
        State              = $vol.State
        Type               = $vol.Type
        SVM_DR_Protection  = $hasSvmDR
        Has_SnapMirror     = $hasSM
        DR_Dest_Count      = $sorted.Count
        # Dest 1 (cluster-Nidr preferred)
        DR1_Cluster        = if ($d1) { $d1.DestCluster } else { '' }
        DR1_SVM            = if ($d1) { $d1.DestSVM } else { '' }
        DR1_Volume         = if ($d1) { $d1.DestVolume } else { '' }
        DR1_PolicyType     = if ($d1) { $d1.PolicyType } else { '' }
        DR1_Status         = if ($d1) { $d1.Status } else { '' }
        DR1_State          = if ($d1) { $d1.State } else { '' }
        DR1_Healthy        = if ($d1) { $d1.Healthy } else { '' }
        # Dest 2
        DR2_Cluster        = if ($d2) { $d2.DestCluster } else { '' }
        DR2_SVM            = if ($d2) { $d2.DestSVM } else { '' }
        DR2_Volume         = if ($d2) { $d2.DestVolume } else { '' }
        DR2_PolicyType     = if ($d2) { $d2.PolicyType } else { '' }
        DR2_Status         = if ($d2) { $d2.Status } else { '' }
        DR2_State          = if ($d2) { $d2.State } else { '' }
        DR2_Healthy        = if ($d2) { $d2.Healthy } else { '' }
        # Dest 3
        DR3_Cluster        = if ($d3) { $d3.DestCluster } else { '' }
        DR3_SVM            = if ($d3) { $d3.DestSVM } else { '' }
        DR3_Volume         = if ($d3) { $d3.DestVolume } else { '' }
        DR3_PolicyType     = if ($d3) { $d3.PolicyType } else { '' }
        DR3_Status         = if ($d3) { $d3.Status } else { '' }
        DR3_State          = if ($d3) { $d3.State } else { '' }
        DR3_Healthy        = if ($d3) { $d3.Healthy } else { '' }
    }
    $csvRows += $row
}

# ============================================================
# Step 8: Export and report
# ============================================================
$csvRows | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Host "`nCSV exported to: $OutputPath" -ForegroundColor Green
Write-Host "Total rows: $($csvRows.Count)" -ForegroundColor Green
$withSM = ($csvRows | Where-Object { $_.Has_SnapMirror -eq 'Yes' }).Count
$withoutDR = ($csvRows | Where-Object { $_.Has_SnapMirror -eq 'No' -and $_.SVM_DR_Protection -eq 'No' }).Count
$brokenOff = ($csvRows | Where-Object { $_.DR1_State -eq 'Broken-off' -or $_.DR2_State -eq 'Broken-off' -or $_.DR3_State -eq 'Broken-off' }).Count
Write-Host "  With SnapMirror DR: $withSM" -ForegroundColor Yellow
Write-Host "  Broken-off mirrors: $brokenOff" -ForegroundColor Red
Write-Host "  Without any DR: $withoutDR" -ForegroundColor Red

# Summary by SVM
Write-Host "`n--- Volume count by SVM ---" -ForegroundColor Cyan
$csvRows | Group-Object Source_SVM | Select-Object @{N='SVM';E={$_.Name}}, Count | Sort-Object Count -Desc | Format-Table -AutoSize
