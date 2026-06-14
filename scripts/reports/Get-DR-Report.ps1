<#
.SYNOPSIS
    DR Status Report — SnapMirror protection coverage by cluster group.
.DESCRIPTION
    Connects to ONTAP clusters filtered by SnapmirrorGroup (from config.json),
    collects volumes and SnapMirror relationships via ZAPI, and produces a CSV
    report showing which RW volumes have DR protection and where.

    Groups are defined per cluster in config.json (e.g. "NI", "Corp").
    Run without -SnapmirrorGroup to report on all groups.
.PARAMETER SnapmirrorGroup
    Optional. Filter to a specific group (e.g. "NI", "Corp").
    Omit to run for all groups that have clusters assigned.
.PARAMETER OutputPath
    CSV output path. Defaults to .\DR_Report_<Group>_<date>.csv
.EXAMPLE
    .\Get-DR-Report.ps1
    # All groups
.EXAMPLE
    .\Get-DR-Report.ps1 -SnapmirrorGroup Corp
    # Corp group only
.EXAMPLE
    .\Get-DR-Report.ps1 -SMirrorG NI
    # NI group only
#>
param(
    [Alias('SMirrorG')]
    [string]$SnapmirrorGroup,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

# ============================================================
# Load config
# ============================================================
$rootDir = (Resolve-Path "$PSScriptRoot\..\..").Path
. "$rootDir\Load-Config.ps1"

# ============================================================
# Filter clusters by group
# ============================================================
$allGrouped = $ONTAP_Clusters | Where-Object { $_.SnapmirrorGroup }

if ($SnapmirrorGroup) {
    $targetClusters = $allGrouped | Where-Object { $_.SnapmirrorGroup -eq $SnapmirrorGroup }
    if (-not $targetClusters) {
        $available = ($allGrouped | Select-Object -ExpandProperty SnapmirrorGroup -Unique) -join ', '
        throw "No clusters in group '$SnapmirrorGroup'. Available groups: $available"
    }
    $groups = @($SnapmirrorGroup)
} else {
    $targetClusters = $allGrouped
    $groups = @($allGrouped | Select-Object -ExpandProperty SnapmirrorGroup -Unique)
}

Write-Host "SnapMirror Groups : $($groups -join ', ')" -ForegroundColor Cyan
Write-Host "Clusters in scope : $($targetClusters.ClusterName -join ', ')" -ForegroundColor Cyan

# Default output path
if (-not $OutputPath) {
    $tag = if ($SnapmirrorGroup) { $SnapmirrorGroup } else { 'All' }
    $OutputPath = ".\DR_Report_${tag}_$(Get-Date -Format 'yyyyMMdd').csv"
}

# ============================================================
# Step 1: Connect to all clusters in scope
# ============================================================
Write-Host "`nConnecting to clusters..." -ForegroundColor Cyan

$controllers = @{}
foreach ($cl in $targetClusters) {
    $addr = if ($cl.FallbackIP) { $cl.FallbackIP } else { $cl.ConnectName }
    Write-Host "  $($cl.ClusterName) ($addr)..." -NoNewline
    try {
        $controllers[$cl.ClusterName] = Connect-NcController $addr
        Write-Host " OK" -ForegroundColor Green
    } catch {
        Write-Host " FAILED: $_" -ForegroundColor Red
    }
}

if ($controllers.Count -eq 0) { throw "No clusters connected." }

# ============================================================
# Step 2: Build SVM -> Cluster mapping (for SnapMirror resolution)
# ============================================================
Write-Host "`nBuilding SVM-to-cluster map..." -ForegroundColor Cyan
$svmToCluster = @{}
foreach ($clName in $controllers.Keys) {
    try {
        $svms = Get-NcVserver -Controller $controllers[$clName]
        foreach ($svm in $svms) { $svmToCluster[$svm.Vserver] = $clName }
    } catch {
        Write-Host "  Warning: Could not list SVMs from $clName" -ForegroundColor Yellow
    }
}
Write-Host "  Mapped $($svmToCluster.Count) SVMs across $($controllers.Count) clusters" -ForegroundColor Green

# ============================================================
# Step 3: Collect volumes from all clusters
# ============================================================
Write-Host "`nCollecting volumes..." -ForegroundColor Cyan

$allVols = @()
foreach ($clName in $controllers.Keys) {
    $vols = Get-NcVol -Controller $controllers[$clName] | Select-Object `
        Vserver, Name, Aggregate,
        @{N='SizeGB';E={[math]::Round($_.TotalSize / 1GB, 2)}},
        @{N='UsedGB';E={[math]::Round($_.VolumeSpaceAttributes.SizeUsed / 1GB, 2)}},
        @{N='UsedPercent';E={$_.VolumeSpaceAttributes.PercentageSizeUsed}},
        State, JunctionPath,
        @{N='Type';E={$_.VolumeIdAttributes.Type}},
        @{N='StyleExtended';E={$_.VolumeIdAttributes.StyleExtended}},
        @{N='VserverDrProtection';E={$_.VserverDrProtection}}

    $clGroup = ($targetClusters | Where-Object { $_.ClusterName -eq $clName }).SnapmirrorGroup

    foreach ($v in $vols) {
        $allVols += [PSCustomObject]@{
            SourceCluster       = $clName
            SourceSVM           = $v.Vserver
            Volume              = $v.Name
            Aggregate           = $v.Aggregate
            SizeGB              = $v.SizeGB
            UsedGB              = $v.UsedGB
            UsedPercent         = $v.UsedPercent
            State               = $v.State
            JunctionPath        = $v.JunctionPath
            Type                = $v.Type
            StyleExtended       = $v.StyleExtended
            VserverDrProtection = $v.VserverDrProtection
            Group               = $clGroup
        }
    }
    Write-Host "  $clName : $($vols.Count) volumes" -ForegroundColor Green
}

# Only RW volumes go into the report (DP volumes are destinations)
$rwVols = $allVols | Where-Object { $_.Type -eq 'rw' }
Write-Host "Total RW volumes in scope: $($rwVols.Count)" -ForegroundColor Green

# ============================================================
# Step 4: Collect SnapMirror relationships from all clusters
# ============================================================
Write-Host "`nCollecting SnapMirror relationships..." -ForegroundColor Cyan

$allSnapMirrors = @()
foreach ($clName in $controllers.Keys) {
    $smList = Get-NcSnapmirror -Controller $controllers[$clName]

    foreach ($sm in $smList) {
        # Parse source/dest from Location fields when individual fields are empty
        $srcVserver = $sm.SourceVserver
        $srcVolume  = $sm.SourceVolume
        if (-not $srcVolume -and $sm.SourceLocation -match '^([^:]+):(.+)$') {
            if (-not $srcVserver) { $srcVserver = $Matches[1] }
            $srcVolume = $Matches[2]
        }
        $dstVserver = $sm.DestinationVserver
        $dstVolume  = $sm.DestinationVolume
        if (-not $dstVolume -and $sm.DestinationLocation -match '^([^:]+):(.+)$') {
            if (-not $dstVserver) { $dstVserver = $Matches[1] }
            $dstVolume = $Matches[2]
        }

        # Resolve cluster names from ZAPI fields, then fall back to SVM mapping
        $srcCluster = $sm.SourceCluster
        if (-not $srcCluster -and $srcVserver) { $srcCluster = $svmToCluster[$srcVserver] }
        $dstCluster = $sm.DestinationCluster
        if (-not $dstCluster -and $dstVserver) { $dstCluster = $svmToCluster[$dstVserver] }

        $allSnapMirrors += [PSCustomObject]@{
            CollectedFrom          = $clName
            SourceLocation         = $sm.SourceLocation
            SourceCluster          = $srcCluster
            SourceVserver          = $srcVserver
            SourceVolume           = $srcVolume
            DestinationLocation    = $sm.DestinationLocation
            DestinationCluster     = $dstCluster
            DestinationVserver     = $dstVserver
            DestinationVolume      = $dstVolume
            RelationshipType       = $sm.RelationshipType
            RelationshipStatus     = $sm.RelationshipStatus
            MirrorState            = $sm.MirrorState
            Policy                 = $sm.Policy
            Schedule               = $sm.Schedule
            IsHealthy              = $sm.IsHealthy
            UnhealthyReason        = $sm.UnhealthyReason
            LagTime                = $sm.LagTime
            LastTransferType       = $sm.LastTransferType
            LastTransferSize       = $sm.LastTransferSize
            LastTransferDuration   = $sm.LastTransferDuration
            NewestSnapshotTimestamp = $sm.NewestSnapshotTimestamp
            RelationshipId         = $sm.RelationshipId
        }
    }
    Write-Host "  $clName : $($smList.Count) snapmirror relationships" -ForegroundColor Green
}

Write-Host "Total SnapMirror relationships: $($allSnapMirrors.Count)" -ForegroundColor Green

# ============================================================
# Step 5: Deduplicate by RelationshipId — prefer destination-side record
# ============================================================
$smByRelId = @{}
foreach ($sm in $allSnapMirrors) {
    $rid = $sm.RelationshipId
    if (-not $rid) { $rid = "$($sm.SourceLocation)->$($sm.DestinationLocation)" }

    if (-not $smByRelId.ContainsKey($rid)) {
        $smByRelId[$rid] = $sm
    } else {
        $existing = $smByRelId[$rid]
        # Prefer the record collected from the destination cluster (has health/lag)
        if ($sm.CollectedFrom -eq $sm.DestinationCluster -and
            $existing.CollectedFrom -ne $existing.DestinationCluster) {
            $smByRelId[$rid] = $sm
        }
    }
}
$uniqueSM = @($smByRelId.Values)
Write-Host "Unique SnapMirror relationships: $($uniqueSM.Count)" -ForegroundColor Green

# ============================================================
# Step 6: Build lookup tables
# ============================================================
# Outbound: source SVM:Volume -> list of SM records
$smBySrc = @{}
foreach ($sm in $uniqueSM) {
    $key = "$($sm.SourceVserver):$($sm.SourceVolume)"
    if (-not $smBySrc.ContainsKey($key)) { $smBySrc[$key] = @() }
    $smBySrc[$key] += $sm
}

# Inbound: destination SVM:Volume -> list of SM records
$smByDst = @{}
foreach ($sm in $uniqueSM) {
    $key = "$($sm.DestinationVserver):$($sm.DestinationVolume)"
    if (-not $smByDst.ContainsKey($key)) { $smByDst[$key] = @() }
    $smByDst[$key] += $sm
}

# ============================================================
# Step 7: Build enriched report
# ============================================================
Write-Host "`nBuilding report..." -ForegroundColor Cyan

$csvRows = @()
foreach ($vol in $rwVols) {
    $srcKey = "$($vol.SourceSVM):$($vol.Volume)"

    $asSource = $smBySrc[$srcKey]                       # outbound mirrors
    $asDest   = $smByDst[$srcKey]                       # inbound mirrors
    $isDestination = $asDest -and $asDest.Count -gt 0

    # Sort outbound mirrors alphabetically by destination cluster
    $sorted = @()
    if ($asSource) { $sorted = @($asSource | Sort-Object DestinationCluster) }

    # DR status summary
    $drStatus = if ($sorted.Count -gt 0) {
        $destClusters = ($sorted | ForEach-Object { $_.DestinationCluster } | Select-Object -Unique) -join '; '
        "DR to $destClusters"
    } elseif ($isDestination) {
        $fromClusters = ($asDest | ForEach-Object { $_.SourceCluster } | Select-Object -Unique) -join '; '
        "Destination from: $fromClusters"
    } else {
        'No DR'
    }

    $d_in = if ($isDestination) { $asDest[0] } else { $null }
    $d1 = if ($sorted.Count -ge 1) { $sorted[0] } else { $null }
    $d2 = if ($sorted.Count -ge 2) { $sorted[1] } else { $null }
    $d3 = if ($sorted.Count -ge 3) { $sorted[2] } else { $null }

    $row = [PSCustomObject]@{
        Group                  = $vol.Group
        Source_Cluster         = $vol.SourceCluster
        Source_SVM             = $vol.SourceSVM
        Volume                 = $vol.Volume
        SizeGB                 = $vol.SizeGB
        UsedGB                 = $vol.UsedGB
        UsedPercent            = $vol.UsedPercent
        Aggregate              = $vol.Aggregate
        JunctionPath           = $vol.JunctionPath
        State                  = $vol.State
        StyleExtended          = $vol.StyleExtended
        VserverDR_Protection   = $vol.VserverDrProtection
        DR_Status              = $drStatus
        Is_Destination         = $isDestination
        Outbound_Mirror_Count  = $sorted.Count
        # Inbound (if this RW volume is also a destination somehow)
        Inbound_SourceCluster  = if ($d_in) { $d_in.SourceCluster } else { '' }
        Inbound_SourceSVM      = if ($d_in) { $d_in.SourceVserver } else { '' }
        Inbound_SourceVolume   = if ($d_in) { $d_in.SourceVolume } else { '' }
        Inbound_MirrorState    = if ($d_in) { $d_in.MirrorState } else { '' }
        Inbound_Healthy        = if ($d_in) { $d_in.IsHealthy } else { '' }
        # Outbound Mirror 1
        DR1_DestCluster        = if ($d1) { $d1.DestinationCluster } else { '' }
        DR1_DestSVM            = if ($d1) { $d1.DestinationVserver } else { '' }
        DR1_DestVolume         = if ($d1) { $d1.DestinationVolume } else { '' }
        DR1_MirrorState        = if ($d1) { $d1.MirrorState } else { '' }
        DR1_Status             = if ($d1) { $d1.RelationshipStatus } else { '' }
        DR1_Healthy            = if ($d1) { $d1.IsHealthy } else { '' }
        DR1_Policy             = if ($d1) { $d1.Policy } else { '' }
        DR1_Schedule           = if ($d1) { $d1.Schedule } else { '' }
        DR1_LagTime            = if ($d1) { $d1.LagTime } else { '' }
        DR1_LastTransferType   = if ($d1) { $d1.LastTransferType } else { '' }
        DR1_NewestSnapshot     = if ($d1) { $d1.NewestSnapshotTimestamp } else { '' }
        DR1_Type               = if ($d1) { $d1.RelationshipType } else { '' }
        # Outbound Mirror 2
        DR2_DestCluster        = if ($d2) { $d2.DestinationCluster } else { '' }
        DR2_DestSVM            = if ($d2) { $d2.DestinationVserver } else { '' }
        DR2_DestVolume         = if ($d2) { $d2.DestinationVolume } else { '' }
        DR2_MirrorState        = if ($d2) { $d2.MirrorState } else { '' }
        DR2_Status             = if ($d2) { $d2.RelationshipStatus } else { '' }
        DR2_Healthy            = if ($d2) { $d2.IsHealthy } else { '' }
        DR2_Policy             = if ($d2) { $d2.Policy } else { '' }
        DR2_LagTime            = if ($d2) { $d2.LagTime } else { '' }
        DR2_Type               = if ($d2) { $d2.RelationshipType } else { '' }
        # Outbound Mirror 3
        DR3_DestCluster        = if ($d3) { $d3.DestinationCluster } else { '' }
        DR3_DestSVM            = if ($d3) { $d3.DestinationVserver } else { '' }
        DR3_DestVolume         = if ($d3) { $d3.DestinationVolume } else { '' }
        DR3_MirrorState        = if ($d3) { $d3.MirrorState } else { '' }
        DR3_Healthy            = if ($d3) { $d3.IsHealthy } else { '' }
        DR3_Type               = if ($d3) { $d3.RelationshipType } else { '' }
    }
    $csvRows += $row
}

# ============================================================
# Step 8: Export raw SnapMirror data + report CSV
# ============================================================
$smRawPath = $OutputPath -replace '\.csv$', '_SnapMirrors_Raw.csv'
$uniqueSM | Export-Csv -Path $smRawPath -NoTypeInformation -Encoding UTF8
Write-Host "`nRaw SnapMirror data: $smRawPath" -ForegroundColor Gray

$csvRows | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Host "`n========================================" -ForegroundColor Green
Write-Host "Report exported to : $OutputPath" -ForegroundColor Green
Write-Host "Total volume rows  : $($csvRows.Count)" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green

# ============================================================
# Step 9: Summary
# ============================================================
foreach ($g in $groups) {
    $gRows = $csvRows | Where-Object { $_.Group -eq $g }
    if (-not $gRows) { continue }

    Write-Host "`n--- Group: $g ($($gRows.Count) RW volumes) ---" -ForegroundColor Cyan

    $withDR = ($gRows | Where-Object { $_.Outbound_Mirror_Count -gt 0 }).Count
    $noDR   = ($gRows | Where-Object { $_.Outbound_Mirror_Count -eq 0 -and $_.Is_Destination -ne $true }).Count
    $isDest = ($gRows | Where-Object { $_.Is_Destination -eq $true }).Count

    Write-Host "  With DR mirrors : $withDR" -ForegroundColor Green
    Write-Host "  No DR at all    : $noDR" -ForegroundColor Red
    Write-Host "  Is destination  : $isDest" -ForegroundColor Yellow

    Write-Host "  Per cluster:" -ForegroundColor DarkGray
    $gRows | Group-Object Source_Cluster | ForEach-Object {
        Write-Host "    $($_.Name) : $($_.Count) volumes" -ForegroundColor White
    }
}

Write-Host "`nDR Status breakdown:" -ForegroundColor Cyan
$csvRows | Group-Object DR_Status |
    Select-Object @{N='Status';E={$_.Name}}, Count |
    Sort-Object Count -Descending |
    Format-Table -AutoSize

Write-Host "Volumes per SVM:" -ForegroundColor Cyan
$csvRows | Group-Object Group, Source_Cluster, Source_SVM |
    Select-Object @{N='Group_Cluster_SVM';E={$_.Name}}, Count |
    Sort-Object Group_Cluster_SVM |
    Format-Table -AutoSize
