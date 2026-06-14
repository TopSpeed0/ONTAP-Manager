<# some notes

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

Save the NDMP password as it will be needed later!

# enable on vserver
vserver services ndmp on -vserver MGMT_Vserver
#>
try { import-Module NetApp.ONTAP -ErrorAction Stop } catch {
    Write-Host "Failed to NetApp.ONTAP !" -ForegroundColor Red
    return
}

# node info ( need only for source node )
$SrcCluster = ""          # e.g. "my-cluster-01"
$DstCluster = ""          # e.g. "my-cluster-02"

# Paths to copy from and to
$SourcePath2Copy      = "" # e.g. "/svm_nas/vol1/data"
$DesinationPathTarget = "" # e.g. "/svm_nas_dst/vol2/data"

# Source Access info (NDMP backupuser credentials — see prerequisites above)
$sourceAccessuser = "backupuser"
$sourceAccess     = ""     # NDMP password from: ndmp generate-password

# Destination Access info
$DesinationAccessuser = "backupuser"
$DesinationAccess     = "" # NDMP password from: ndmp generate-password

# fix delegation
reg add "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Cryptography\Protect\Providers\df9d8cd0-1501-11d1-8c7a-00c04fc297eb" /v ProtectionPolicy /t REG_DWORD /d 1 /f

# Check for existing credentials or prompt for them
if (Get-NcCredential -Controller $SrcCluster) {
    Write-Host "Found existing credentials for $SrcCluster" -ForegroundColor Green
}
else {
    Write-Host "No existing credentials for $SrcCluster, please provide" -ForegroundColor Yellow
    try { Add-NcCredential -Controller $SrcCluster -Credential (Get-Credential) -ErrorAction Stop } catch {
        Write-Host "Failed Add-NcCredential For:$($DstCluster) ERR:$($_.Exception.Message)" -ForegroundColor Red
        return
    } 
}

if (Get-NcCredential -Controller $DstCluster) {
    Write-Host "Found existing credentials for $DstCluster" -ForegroundColor Green
}
else {
    Write-Host "No existing credentials for $DstCluster, please provide" -ForegroundColor Yellow
    try { Add-NcCredential -Controller $DstCluster -Credential (Get-Credential) -ErrorAction Stop } catch {
        Write-Host "Failed Add-NcCredential For:$($DstCluster) ERR:$($_.Exception.Message)" -ForegroundColor Red
        return
    } 
}

# Connect to source cluster
try {
    connect-NcController -Name $SrcCluster -ErrorAction Stop
    Write-Host "Connected to source cluster $SrcCluster" -ForegroundColor Green
}
catch {
    Write-Host "Failed to connect to source cluster $SrcCluster. $_" -ForegroundColor Red
    return
}

# loading optimal LIF for source node management
$SRCvserver = $((Get-NcVserver | ? { $_.vserverType -eq "admin" }).Vserver)
$SRCvserver = if ($null -eq $SRCvserver) { (Get-NcCluster).NcController.name }
try { 
    $NcNetInterface = Get-NcNetInterface -Vserver $SRCvserver -FirewallPolicy mgmt -Role node_mgmt 
}
catch {
    Write-Host "Failed to Get Interface on $SrcCluster !" -ForegroundColor Red
    return
}
if (!$NcNetInterface) {
    Write-Warning -Message "Failed to Get Interface on:$SRCvserver Fall Back to more simple method"
    $NcNetInterface = Get-NcNetInterface *mgmt*
}
$reconectSrc = $false

# Get source volume and home volume,aggregate,lif info 
$srcVol = $SourcePath2Copy.split('/')[2]
$srcVol = get-ncvol -volume  "$srcVol"
$SRCNode = (Get-NcAggr (get-ncvol $srcVol).Aggregate).Nodes
$homeNodeVolSRC = $NcNetInterface | ? { $_.HomeNode -match $SRCNode }
$SourceStorageLif = $homeNodeVolSRC.Address

# if source and destination clusters are different as some time we are copying between clusters and some time within same cluster.
if ($DstCluster -ne $SrcCluster) {
    # Connect to destination cluster
    try {
        connect-NcController -Name $DstCluster -ErrorAction Stop
        Write-Host "Connected to destination cluster $DstCluster" -ForegroundColor Green
    }
    catch {
        Write-Host "Failed to connect to destination cluster $DstCluster. $_" -ForegroundColor Red
        return
    }
    $reconectSrc = $true
    $DSTvserver = $((Get-NcVserver | ? { $_.vserverType -eq "admin" }).Vserver)
    $DSTvserver = if ($null -eq $DSTvserver) { (Get-NcCluster).NcController.name }
    try { 
        $NcNetInterface = Get-NcNetInterface -Vserver $DSTvserver -FirewallPolicy mgmt -Role node_mgmt 
    }
    catch {
        Write-Host "Failed to Get Interface on $SrcCluster !" -ForegroundColor Red
        return
    }
    if (!$NcNetInterface) {
        Write-Warning -Message "Failed to Get Interface on:$SRCvserver Fall Back to more simple method"
        $NcNetInterface = Get-NcNetInterface *mgmt*
    }
}

# Get destination volume and home volume,aggregate,lif info 
$dstVol = $DesinationPathTarget.split('/')[2]
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
$SAcred = "$sourceAccessuser`:$sourceAccess"
$SRCpath = "$SourceStorageLif`:$SourcePath2Copy"
# DST
$DAcred = "$DesinationAccessuser`:$DesinationAccess"
$DSTpath = "$DesinationStorageLif`:$DesinationPathTarget"

# Command buildup
$sshCommand = "run -node $SRCNode ndmpcopy -sa $SAcred -da $DAcred $SRCpath $DSTpath"

# if we connected to destination cluster, we need to reconnect to source cluster before invoking the command
if ($reconectSrc) {
    # Reconnect to source cluster
    connect-NcController -Name $SrcCluster
}

# invoke command
Write-host "Executing NDMP copy command:`n$sshCommand" -ForegroundColor Green
invoke-ncSsh -ControllerName $SrcCluster -Command $($sshCommand) -verbose