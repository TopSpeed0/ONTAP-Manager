<#
.SYNOPSIS
    NDMP cross-cluster file copy using config.json for cluster lookups and NDMP credentials.
.DESCRIPTION
    Copies files between NetApp ONTAP clusters using ndmpcopy.
    Cluster names and NDMP passwords are loaded from config.json (NdmpPassword field per cluster).
    Use -SrcCluster / -DstCluster with any Alias, ClusterName, or ConnectName from config.
.PARAMETER SrcCluster
    Source cluster Alias, ClusterName, or ConnectName (from config.json).
.PARAMETER DstCluster
    Destination cluster Alias, ClusterName, or ConnectName.
.PARAMETER SourcePath
    NDMP source path, e.g. "/svm_nas/vol1/data".
.PARAMETER DestPath
    NDMP destination path, e.g. "/svm_nas_dst/vol2/data".
.EXAMPLE
    # Zero-config — reads SrcCluster, DstCluster, SRC, DST from config.json NDMP_Config:
    .\Ndmp_Copy.ps1

.EXAMPLE
    # Override with explicit params:
    .\Ndmp_Copy.ps1 -SrcCluster SrcAlias -DstCluster DstAlias -SourcePath "/src_svm/src_vol/path" -DestPath "/dst_svm/dst_vol/path"

Prerequisites: ENABLE NDMP on both source and destination clusters

*** Enable NDMP on Cluster and create backupuser on ADMIN vserver with backup role ***

# Enable NDMP to be enabled "cluster wide" with a special root user (this is not a normal root user !!!)
::> system services ndmp modify -node * -enable true -user-id root

# Enable ndmpcopy to be ran on all nodes
::> node run -node * -command options nodescope.reenabledcmds ndmpcopy

# Enable the ndmp system service on all nodes
::> system services ndmp on -node *

# Ensure "node-scope-mode" is disabled, so we can use clusterip:/vserver/volume pathing
::> system services ndmp node-scope-mode off

# Find the name of the ADMIN (cluster) vserver (MGMT_Vserver)
::> vserver show -type admin

# Find the CLUSTER admin IP (same one you ssh into)
::> network interface show -role cluster-mgmt

# Create backupuser for NDMP Copy
::> security login create -vserver MGMT_Vserver -username backupuser  -application ssh -authmethod password -role backup

# Create a "backupuser" account on the ADMIN (cluster) vserver with the proper role to be able to use ndmpcopy
::> vserver services ndmp generate-password -vserver MGMT_Vserver -user backupuser

Save the NDMP password in config.json under the cluster's "NdmpPassword" field!

# enable on vserver
vserver services ndmp on -vserver MGMT_Vserver
#>
param(
    [string]$SrcCluster,
    [string]$DstCluster,
    [string]$SourcePath,
    [string]$DestPath
)

$ErrorActionPreference = 'Stop'

# --- Load config.json -------------------------------------------------------
$rootDir = (Resolve-Path "$PSScriptRoot\..\..").Path
$configPath = Join-Path $rootDir 'config.json'
if (-not (Test-Path $configPath)) {
    Write-Host "config.json not found at $configPath — run Load-Config.ps1 first." -ForegroundColor Red
    return
}
$config = Get-Content $configPath -Raw | ConvertFrom-Json
$ndmpCfg  = $config.NDMP_Config
$ndmpUser = $ndmpCfg.BackupUser

# --- Fall back to NDMP_Config defaults if params not supplied ----------------
if ([string]::IsNullOrWhiteSpace($SrcCluster)) { $SrcCluster = $ndmpCfg.SrcCluster }
if ([string]::IsNullOrWhiteSpace($DstCluster)) { $DstCluster = $ndmpCfg.DstCluster }
if ([string]::IsNullOrWhiteSpace($SourcePath)) { $SourcePath  = $ndmpCfg.SRC }
if ([string]::IsNullOrWhiteSpace($DestPath))   { $DestPath    = $ndmpCfg.DST }

# Validate we have all required values
foreach ($pair in @(
    @('SrcCluster', $SrcCluster), @('DstCluster', $DstCluster),
    @('SourcePath', $SourcePath), @('DestPath',   $DestPath)
)) {
    if ([string]::IsNullOrWhiteSpace($pair[1])) {
        Write-Host "Missing '$($pair[0])' — pass as parameter or set in config.json NDMP_Config." -ForegroundColor Red
        return
    }
}

# --- Resolve clusters from config -------------------------------------------
function Find-ClusterConfig {
    param([string]$Name, [object]$Config)
    $match = $Config.ONTAP_Clusters | Where-Object {
        $_.Alias -eq $Name -or $_.ClusterName -eq $Name -or $_.ConnectName -eq $Name
    }
    if (-not $match) { throw "Cluster '$Name' not found in config.json" }
    return $match
}

$srcCfg = Find-ClusterConfig -Name $SrcCluster -Config $config
$dstCfg = Find-ClusterConfig -Name $DstCluster -Config $config

$SrcClusterConnect = $srcCfg.ConnectName
$DstClusterConnect = $dstCfg.ConnectName

# --- NDMP passwords from config ---------------------------------------------
$sourceAccess = $srcCfg.NdmpPassword
$destAccess   = $dstCfg.NdmpPassword

if ([string]::IsNullOrWhiteSpace($sourceAccess)) {
    Write-Host "No NdmpPassword configured for source cluster '$($srcCfg.Alias)' in config.json" -ForegroundColor Red
    return
}
if ([string]::IsNullOrWhiteSpace($destAccess)) {
    Write-Host "No NdmpPassword configured for destination cluster '$($dstCfg.Alias)' in config.json" -ForegroundColor Red
    return
}

Write-Host "NDMP Copy: $($srcCfg.Alias) -> $($dstCfg.Alias)" -ForegroundColor Cyan
Write-Host "  Source:      $SourcePath" -ForegroundColor DarkGray
Write-Host "  Destination: $DestPath" -ForegroundColor DarkGray

# --- Load DataONTAP module ---------------------------------------------------
try { Import-Module NetApp.ONTAP -ErrorAction Stop } catch {
    Write-Host "Failed to load NetApp.ONTAP module!" -ForegroundColor Red
    return
}

# fix delegation
reg add "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Cryptography\Protect\Providers\df9d8cd0-1501-11d1-8c7a-00c04fc297eb" /v ProtectionPolicy /t REG_DWORD /d 1 /f

# Check for existing credentials or prompt for them
if (Get-NcCredential -Controller $SrcClusterConnect) {
    Write-Host "Found existing credentials for $SrcClusterConnect" -ForegroundColor Green
}
else {
    Write-Host "No existing credentials for $SrcClusterConnect, please provide" -ForegroundColor Yellow
    try { Add-NcCredential -Controller $SrcClusterConnect -Credential (Get-Credential) -ErrorAction Stop } catch {
        Write-Host "Failed Add-NcCredential For:$($SrcClusterConnect) ERR:$($_.Exception.Message)" -ForegroundColor Red
        return
    } 
}

if (Get-NcCredential -Controller $DstClusterConnect) {
    Write-Host "Found existing credentials for $DstClusterConnect" -ForegroundColor Green
}
else {
    Write-Host "No existing credentials for $DstClusterConnect, please provide" -ForegroundColor Yellow
    try { Add-NcCredential -Controller $DstClusterConnect -Credential (Get-Credential) -ErrorAction Stop } catch {
        Write-Host "Failed Add-NcCredential For:$($DstClusterConnect) ERR:$($_.Exception.Message)" -ForegroundColor Red
        return
    } 
}

# Connect to source cluster
try {
    Connect-NcController -Name $SrcClusterConnect -ErrorAction Stop
    Write-Host "Connected to source cluster $SrcClusterConnect" -ForegroundColor Green
}
catch {
    Write-Host "Failed to connect to source cluster $SrcClusterConnect. $_" -ForegroundColor Red
    return
}

# loading optimal LIF for source node management
$SRCvserver = $((Get-NcVserver | ? { $_.vserverType -eq "admin" }).Vserver)
$SRCvserver = if ($null -eq $SRCvserver) { (Get-NcCluster).NcController.name }
try { 
    $NcNetInterface = Get-NcNetInterface -Vserver $SRCvserver -FirewallPolicy mgmt -Role node_mgmt 
}
catch {
    Write-Host "Failed to Get Interface on $SrcClusterConnect !" -ForegroundColor Red
    return
}
if (!$NcNetInterface) {
    Write-Warning -Message "Failed to Get Interface on:$SRCvserver Fall Back to more simple method"
    $NcNetInterface = Get-NcNetInterface *mgmt*
}
$reconectSrc = $false

# Get source volume and home volume,aggregate,lif info 
$srcVol = $SourcePath.split('/')[2]
$srcVol = get-ncvol -volume  "$srcVol"
$SRCNode = (Get-NcAggr (get-ncvol $srcVol).Aggregate).Nodes
$homeNodeVolSRC = $NcNetInterface | ? { $_.HomeNode -match $SRCNode }
$SourceStorageLif = $homeNodeVolSRC.Address

# if source and destination clusters are different as some time we are copying between clusters and some time within same cluster.
if ($DstClusterConnect -ne $SrcClusterConnect) {
    # Connect to destination cluster
    try {
        Connect-NcController -Name $DstClusterConnect -ErrorAction Stop
        Write-Host "Connected to destination cluster $DstClusterConnect" -ForegroundColor Green
    }
    catch {
        Write-Host "Failed to connect to destination cluster $DstClusterConnect. $_" -ForegroundColor Red
        return
    }
    $reconectSrc = $true
    $DSTvserver = $((Get-NcVserver | ? { $_.vserverType -eq "admin" }).Vserver)
    $DSTvserver = if ($null -eq $DSTvserver) { (Get-NcCluster).NcController.name }
    try { 
        $NcNetInterface = Get-NcNetInterface -Vserver $DSTvserver -FirewallPolicy mgmt -Role node_mgmt 
    }
    catch {
        Write-Host "Failed to Get Interface on $DstClusterConnect !" -ForegroundColor Red
        return
    }
    if (!$NcNetInterface) {
        Write-Warning -Message "Failed to Get Interface on:$DSTvserver Fall Back to more simple method"
        $NcNetInterface = Get-NcNetInterface *mgmt*
    }
}

# Get destination volume and home volume,aggregate,lif info 
$dstVol = $DestPath.split('/')[2]
$dstVol = get-ncvol -volume  "$dstVol"
$DSTNode = (Get-NcAggr (get-ncvol $dstVol).Aggregate).Nodes
$homeNodeVolDST = $NcNetInterface | ? { $_.HomeNode -match $DSTNode }
$DesinationStorageLif = $homeNodeVolDST.Address

# verify we have found source volume, no volume no copy
if (-not $homeNodeVolSRC) {
    Write-Host "Could not find management LIF for source node $SRCNode" -ForegroundColor Red
    return
}
# verify we have found destination volume, no volume no copy
if (-not $homeNodeVolDST) {
    Write-Host "Could not find management LIF for destination node $DSTNode" -ForegroundColor Red
    return
}

# combined creds and paths
# SRC
$SAcred = "${ndmpUser}:${sourceAccess}"
$SRCpath = "$SourceStorageLif`:$SourcePath"
# DST
$DAcred = "${ndmpUser}:${destAccess}"
$DSTpath = "$DesinationStorageLif`:$DestPath"

# Command buildup
$sshCommand = "run -node $SRCNode ndmpcopy -sa $SAcred -da $DAcred $SRCpath $DSTpath"

# if we connected to destination cluster, we need to reconnect to source cluster before invoking the command
if ($reconectSrc) {
    # Reconnect to source cluster
    Connect-NcController -Name $SrcClusterConnect
}

# invoke command
Write-Host "Executing NDMP copy command:`n$sshCommand" -ForegroundColor Green
Invoke-NcSsh -ControllerName $SrcClusterConnect -Command $($sshCommand) -Verbose