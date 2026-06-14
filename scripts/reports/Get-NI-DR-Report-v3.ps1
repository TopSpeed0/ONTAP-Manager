param(
    [string]$OutputPath = ".\NI_Colo_Volumes_DR_Status_v3.csv"
)

# ============================================================
# NI DR Report — PowerShell ZAPI (DataONTAP module) version
# ============================================================

# Load cluster config
$rootDir = (Resolve-Path "$PSScriptRoot\..\..").Path
. "$rootDir\Load-Config.ps1"

# Helper: resolve connect address from config
function Resolve-ClusterAddr ([string]$Name) {
    $entry = $ONTAP_Clusters | Where-Object { $_.ClusterName -eq $Name -or $_.ConnectName -eq $Name }
    if (-not $entry) { throw "Cluster '$Name' not found in config.json" }
    if ($entry.FallbackIP) { $entry.FallbackIP } else { $entry.ConnectName }
}

# This report covers these specific clusters
$reportClusters = @('cluster-colo1', 'cluster-colo2', 'legacy', 'cluster-Nidr')

# Step 1: Connect to all clusters
Write-Host "Connecting to clusters..." -ForegroundColor Cyan

$controllers = @{}
foreach ($name in $reportClusters) {
    $addr = Resolve-ClusterAddr $name
    Write-Host "  Connecting to $name ($addr)..." -ForegroundColor Gray
    try {
        $controllers[$name] = Connect-NcController $addr
        Write-Host "  Connected to $name" -ForegroundColor Green
    } catch {
        Write-Host "  FAILED to connect to $name : $_" -ForegroundColor Red
    }
}

# ============================================================
# Step 2: Get all volumes from cluster-colo1, cluster-colo2, legacy
# ============================================================
Write-Host "`nCollecting volumes..." -ForegroundColor Cyan

$sourceClusterNames = @('cluster-colo1', 'cluster-colo2', 'legacy')
$allVols = @()

foreach ($clName in $sourceClusterNames) {
    if (-not $controllers.ContainsKey($clName)) {
        Write-Host "  Skipping $clName (not connected)" -ForegroundColor Yellow
        continue
    }
    $vols = Get-NcVol -Controller $controllers[$clName] | Select-Object `
        Vserver, Name, Aggregate, 
        @{N='SizeGB';E={[math]::Round($_.TotalSize / 1GB, 2)}},
        @{N='UsedGB';E={[math]::Round($_.VolumeSpaceAttributes.SizeUsed / 1GB, 2)}},
        @{N='UsedPercent';E={$_.VolumeSpaceAttributes.PercentageSizeUsed}},
        State, JunctionPath, VolumeIdAttributes,
        @{N='Type';E={$_.VolumeIdAttributes.Type}},
        @{N='StyleExtended';E={$_.VolumeIdAttributes.StyleExtended}},
        @{N='Comment';E={$_.VolumeIdAttributes.Comment}},
        @{N='VserverDrProtection';E={$_.VserverDrProtection}}
    
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
            Comment             = $v.Comment
            VserverDrProtection = $v.VserverDrProtection
        }
    }
    Write-Host "  $clName : $($vols.Count) volumes" -ForegroundColor Green
}

Write-Host "Total volumes: $($allVols.Count)" -ForegroundColor Green

# ============================================================
# Step 3: Get SnapMirror relationships from ALL 4 clusters
# ============================================================
Write-Host "`nCollecting SnapMirror relationships..." -ForegroundColor Cyan

$allSnapMirrors = @()

foreach ($clName in $controllers.Keys) {
    if (-not $controllers.ContainsKey($clName)) { continue }
    
    $smList = Get-NcSnapmirror -Controller $controllers[$clName]
    
    foreach ($sm in $smList) {
        # Parse SVM:Volume from Location fields when individual fields are empty
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
        # Resolve DestinationCluster from known SVM names when empty
        $dstCluster = $sm.DestinationCluster
        if (-not $dstCluster) {
            $dstCluster = switch ($dstVserver) {
                'svm_snapmirror_dr'     { 'cluster-Nidr' }
                'svm_snapmirror_backup' { 'legacy' }
                default {
                    # If collected from a destination cluster, that's the dest cluster
                    if ($clName -in @('cluster-Nidr','legacy')) { $clName } else { '' }
                }
            }
        }
        # Resolve SourceCluster from known SVM names when empty
        $srcCluster = $sm.SourceCluster
        if (-not $srcCluster) {
            $srcCluster = switch -Regex ($srcVserver) {
                'colo-svm-cl1|Infra|BigData|Projects|Colo-MC|Colo-GCO|Colo-IMDA|Colo-Kubernetes|Colo-Nightly|Colo-SPFP|Service_Pack|Octopus|Plus|NIP2|IP|EMEA_Americas|STRATEGIX|TechCenter|UserFlow|VX_GA|Telephony_Mapping|SegmentsK8S|Trombonetcs|Backup|appscanner|svm-tmr-cl1' { 'cluster-colo1' }
                'colo-svm-cl2|legacynas-colo|Infra-Playground|Lab-Shares|LP-TEST|Service|tests' { 'cluster-colo2' }
                'legacyvs|MC|_Infra|test' { 'legacy' }
                default { '' }
            }
        }

        $allSnapMirrors += [PSCustomObject]@{
            CollectedFrom      = $clName
            SourceLocation     = $sm.SourceLocation
            SourceCluster      = $srcCluster
            SourceVserver      = $srcVserver
            SourceVolume       = $srcVolume
            DestinationLocation= $sm.DestinationLocation
            DestinationCluster = $dstCluster
            DestinationVserver = $dstVserver
            DestinationVolume  = $dstVolume
            RelationshipType   = $sm.RelationshipType
            RelationshipStatus = $sm.RelationshipStatus
            MirrorState        = $sm.MirrorState
            Policy             = $sm.Policy
            Schedule           = $sm.Schedule
            IsHealthy          = $sm.IsHealthy
            UnhealthyReason    = $sm.UnhealthyReason
            LagTime            = $sm.LagTime
            LastTransferType   = $sm.LastTransferType
            LastTransferSize   = $sm.LastTransferSize
            LastTransferDuration = $sm.LastTransferDuration
            estSnapshotTimestamp = $sm.estSnapshotTimestamp
            RelationshipId     = $sm.RelationshipId
        }
    }
    Write-Host "  $clName : $($smList.Count) snapmirror relationships" -ForegroundColor Green
}

Write-Host "Total SnapMirror relationships: $($allSnapMirrors.Count)" -ForegroundColor Green

# Also get list-destinations from source clusters
Write-Host "`nCollecting SnapMirror list-destinations..." -ForegroundColor Cyan

$allListDest = @()
foreach ($clName in @('cluster-colo1', 'cluster-colo2', 'legacy')) {
    if (-not $controllers.ContainsKey($clName)) { continue }
    
    $ldList = Get-NcSnapmirrorDestination -Controller $controllers[$clName]
    
    foreach ($ld in $ldList) {
        # Parse Location fields
        $srcVserver = $ld.SourceVserver
        $srcVolume  = $ld.SourceVolume
        if (-not $srcVolume -and $ld.SourceLocation -match '^([^:]+):(.+)$') {
            if (-not $srcVserver) { $srcVserver = $Matches[1] }
            $srcVolume = $Matches[2]
        }
        $dstVserver = $ld.DestinationVserver
        $dstVolume  = $ld.DestinationVolume
        if (-not $dstVolume -and $ld.DestinationLocation -match '^([^:]+):(.+)$') {
            if (-not $dstVserver) { $dstVserver = $Matches[1] }
            $dstVolume = $Matches[2]
        }

        $allListDest += [PSCustomObject]@{
            CollectedFrom      = $clName
            SourceLocation     = $ld.SourceLocation
            SourceCluster      = $ld.SourceCluster
            SourceVserver      = $srcVserver
            SourceVolume       = $srcVolume
            DestinationLocation= $ld.DestinationLocation
            DestinationCluster = $ld.DestinationCluster
            DestinationVserver = $dstVserver
            DestinationVolume  = $dstVolume
            RelationshipType   = $ld.RelationshipType
            PolicyType         = $ld.PolicyType
            RelationshipStatus = $ld.RelationshipStatus
            RelationshipId     = $ld.RelationshipId
        }
    }
    Write-Host "  $clName list-destinations: $($ldList.Count)" -ForegroundColor Green
}

# ============================================================
# Step 4: Export raw SnapMirror data to separate CSV for reference
# ============================================================
$smRawPath = $OutputPath -replace '\.csv$', '_SnapMirrors_Raw.csv'
$allSnapMirrors | Export-Csv -Path $smRawPath -NoTypeInformation -Encoding UTF8
Write-Host "`nRaw SnapMirror data exported to: $smRawPath" -ForegroundColor Gray

$ldRawPath = $OutputPath -replace '\.csv$', '_ListDest_Raw.csv'
$allListDest | Export-Csv -Path $ldRawPath -NoTypeInformation -Encoding UTF8
Write-Host "Raw list-destinations data exported to: $ldRawPath" -ForegroundColor Gray

# ============================================================
# Step 5: Deduplicate SnapMirror relationships by RelationshipId
#         Prefer the record collected from the destination cluster
# ============================================================
$smByRelId = @{}
foreach ($sm in $allSnapMirrors) {
    $rid = $sm.RelationshipId
    if (-not $rid) {
        # Use source+dest path as fallback key
        $rid = "$($sm.SourceLocation)->$($sm.DestinationLocation)"
    }
    if (-not $smByRelId.ContainsKey($rid)) {
        $smByRelId[$rid] = $sm
    } else {
        # Prefer destination-side record (has health/lag info)
        $existing = $smByRelId[$rid]
        $destClusters = @('cluster-Nidr', 'legacy')
        if ($sm.CollectedFrom -in $destClusters -and $existing.CollectedFrom -notin $destClusters) {
            $smByRelId[$rid] = $sm
        }
    }
}
$uniqueSM = $smByRelId.Values

# ============================================================
# Step 6: Build lookup: source "SVM:Volume" -> list of SM destinations
# ============================================================
$smBySrc = @{}
foreach ($sm in $uniqueSM) {
    $key = "$($sm.SourceVserver):$($sm.SourceVolume)"
    if (-not $smBySrc.ContainsKey($key)) { $smBySrc[$key] = @() }
    $smBySrc[$key] += $sm
}

# Also index by destination for legacy volumes that are destinations
$smByDst = @{}
foreach ($sm in $uniqueSM) {
    $key = "$($sm.DestinationVserver):$($sm.DestinationVolume)"
    if (-not $smByDst.ContainsKey($key)) { $smByDst[$key] = @() }
    $smByDst[$key] += $sm
}

# ============================================================
# Step 7: Build enriched CSV report
# ============================================================
Write-Host "`nBuilding report..." -ForegroundColor Cyan

$csvRows = @()
foreach ($vol in $allVols) {
    $srcKey = "$($vol.SourceSVM):$($vol.Volume)"
    
    # Mirrors where this volume is the SOURCE
    $asSource = $smBySrc[$srcKey]
    
    # Mirrors where this volume is the DESTINATION
    $asDest = $smByDst[$srcKey]
    
    # Classify DR targets
    $toNidr = @()
    $toLegacy = @()
    $toOther = @()
    
    if ($asSource) {
        foreach ($sm in $asSource) {
            $dc = $sm.DestinationCluster
            $dv = $sm.DestinationVserver
            if ($dc -match 'cluster-Nidr' -or $dv -eq 'svm_snapmirror_dr') {
                $toNidr += $sm
            } elseif ($dc -match 'legacy|10\.164\.233' -or $dv -eq 'svm_snapmirror_backup') {
                $toLegacy += $sm
            } else {
                $toOther += $sm
            }
        }
    }
    
    # Determine DR status
    $hasDrToNidr = $toNidr.Count -gt 0
    $hasDrTolegacy = $toLegacy.Count -gt 0
    $isDestination = $asDest -and $asDest.Count -gt 0
    
    # Migration status logic
    $migrationStatus = ''
    if ($vol.SourceCluster -in @('cluster-colo1', 'cluster-colo2')) {
        if ($hasDrToNidr) {
            $migrationStatus = 'DR to cluster-Nidr (OK)'
        } elseif ($hasDrTolegacy) {
            $migrationStatus = 'DR to legacy (NOT migrated to cluster-Nidr)'
        } else {
            $migrationStatus = 'No DR configured'
        }
    } elseif ($vol.SourceCluster -eq 'legacy') {
        if ($isDestination) {
            $fromSrc = ($asDest | ForEach-Object { $_.SourceCluster }) -join '; '
            $migrationStatus = "legacy is DESTINATION from: $fromSrc (legacy mirror)"
        } elseif ($hasDrToNidr) {
            $migrationStatus = 'legacy source -> cluster-Nidr (OK)'
        } else {
            $migrationStatus = 'legacy local volume (no mirror)'
        }
    }
    
    # Sort mirrors: cluster-Nidr first, then legacy, then other
    $sortedSM = @()
    $sortedSM += $toNidr
    $sortedSM += $toLegacy
    $sortedSM += $toOther
    
    # Get first mirror where this vol is destination
    $d_asDest = if ($asDest -and $asDest.Count -gt 0) { $asDest[0] } else { $null }
    
    # Up to 3 outbound mirrors
    $d1 = if ($sortedSM.Count -ge 1) { $sortedSM[0] } else { $null }
    $d2 = if ($sortedSM.Count -ge 2) { $sortedSM[1] } else { $null }
    $d3 = if ($sortedSM.Count -ge 3) { $sortedSM[2] } else { $null }
    
    $row = [PSCustomObject]@{
        Source_Cluster         = $vol.SourceCluster
        Source_SVM             = $vol.SourceSVM
        Volume                 = $vol.Volume
        SizeGB                 = $vol.SizeGB
        UsedGB                 = $vol.UsedGB
        UsedPercent            = $vol.UsedPercent
        Aggregate              = $vol.Aggregate
        JunctionPath           = $vol.JunctionPath
        State                  = $vol.State
        Type                   = $vol.Type
        StyleExtended          = $vol.StyleExtended
        VserverDR_Protection   = $vol.VserverDrProtection
        Migration_Status       = $migrationStatus
        Has_DR_to_NIDR         = $hasDrToNidr
        Has_DR_to_legacy    = $hasDrTolegacy
        Is_Destination         = $isDestination
        Outbound_Mirror_Count  = $sortedSM.Count
        # If this volume is a DESTINATION
        Inbound_SourceCluster  = if ($d_asDest) { $d_asDest.SourceCluster } else { '' }
        Inbound_SourceSVM      = if ($d_asDest) { $d_asDest.SourceVserver } else { '' }
        Inbound_SourceVolume   = if ($d_asDest) { $d_asDest.SourceVolume } else { '' }
        Inbound_MirrorState    = if ($d_asDest) { $d_asDest.MirrorState } else { '' }
        Inbound_Status         = if ($d_asDest) { $d_asDest.RelationshipStatus } else { '' }
        Inbound_Healthy        = if ($d_asDest) { $d_asDest.IsHealthy } else { '' }
        Inbound_Policy         = if ($d_asDest) { $d_asDest.Policy } else { '' }
        # Outbound Mirror 1 (prefer cluster-Nidr)
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
        DR1_LastTransferSize   = if ($d1) { $d1.LastTransferSize } else { '' }
        DR1_estSnapshot     = if ($d1) { $d1.estSnapshotTimestamp } else { '' }
        DR1_Type               = if ($d1) { $d1.RelationshipType } else { '' }
        # Outbound Mirror 2
        DR2_DestCluster        = if ($d2) { $d2.DestinationCluster } else { '' }
        DR2_DestSVM            = if ($d2) { $d2.DestinationVserver } else { '' }
        DR2_DestVolume         = if ($d2) { $d2.DestinationVolume } else { '' }
        DR2_MirrorState        = if ($d2) { $d2.MirrorState } else { '' }
        DR2_Status             = if ($d2) { $d2.RelationshipStatus } else { '' }
        DR2_Healthy            = if ($d2) { $d2.IsHealthy } else { '' }
        DR2_Policy             = if ($d2) { $d2.Policy } else { '' }
        DR2_Schedule           = if ($d2) { $d2.Schedule } else { '' }
        DR2_LagTime            = if ($d2) { $d2.LagTime } else { '' }
        DR2_Type               = if ($d2) { $d2.RelationshipType } else { '' }
        # Outbound Mirror 3
        DR3_DestCluster        = if ($d3) { $d3.DestinationCluster } else { '' }
        DR3_DestSVM            = if ($d3) { $d3.DestinationVserver } else { '' }
        DR3_DestVolume         = if ($d3) { $d3.DestinationVolume } else { '' }
        DR3_MirrorState        = if ($d3) { $d3.MirrorState } else { '' }
        DR3_Status             = if ($d3) { $d3.RelationshipStatus } else { '' }
        DR3_Healthy            = if ($d3) { $d3.IsHealthy } else { '' }
        DR3_Policy             = if ($d3) { $d3.Policy } else { '' }
        DR3_Type               = if ($d3) { $d3.RelationshipType } else { '' }
    }
    $csvRows += $row
}

# ============================================================
# Step 8: Export and summary
# ============================================================
$csvRows | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Host "`n========================================" -ForegroundColor Green
Write-Host "CSV exported to: $OutputPath" -ForegroundColor Green
Write-Host "Total volume rows: $($csvRows.Count)" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green

# Summary stats
$cl1Vols = ($csvRows | Where-Object { $_.Source_Cluster -eq 'cluster-colo1' }).Count
$cl2Vols = ($csvRows | Where-Object { $_.Source_Cluster -eq 'cluster-colo2' }).Count
$cisvmVols = ($csvRows | Where-Object { $_.Source_Cluster -eq 'legacy' }).Count

Write-Host "`nVolume counts:" -ForegroundColor Cyan
Write-Host "  cluster-colo1 : $cl1Vols" -ForegroundColor White
Write-Host "  cluster-colo2 : $cl2Vols" -ForegroundColor White
Write-Host "  legacy    : $cisvmVols" -ForegroundColor White

$drToNidr = ($csvRows | Where-Object { $_.Has_DR_to_NIDR -eq $true }).Count
$drToCisvm = ($csvRows | Where-Object { $_.Has_DR_to_legacy -eq $true }).Count
$isDest = ($csvRows | Where-Object { $_.Is_Destination -eq $true }).Count
$noDR = ($csvRows | Where-Object { $_.Outbound_Mirror_Count -eq 0 -and $_.Is_Destination -eq $false }).Count

Write-Host "`nDR Summary:" -ForegroundColor Cyan
Write-Host "  Volumes with DR to cluster-Nidr   : $drToNidr" -ForegroundColor Green
Write-Host "  Volumes with DR to legacy    : $drToCisvm (legacy, not migrated)" -ForegroundColor Yellow
Write-Host "  Volumes that ARE destinations   : $isDest" -ForegroundColor Yellow
Write-Host "  Volumes with NO DR at all       : $noDR" -ForegroundColor Red

Write-Host "`nMigration Status breakdown:" -ForegroundColor Cyan
$csvRows | Group-Object Migration_Status | Select-Object @{N='Status';E={$_.Name}}, Count | Sort-Object Count -Desc | Format-Table -AutoSize

Write-Host "`nVolumes per SVM:" -ForegroundColor Cyan
$csvRows | Group-Object Source_Cluster, Source_SVM | Select-Object @{N='Cluster_SVM';E={$_.Name}}, Count | Sort-Object Cluster_SVM | Format-Table -AutoSize
