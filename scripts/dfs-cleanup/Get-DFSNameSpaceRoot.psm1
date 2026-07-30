#Requires -Version 7
#Requires -Modules NetApp.ONTAP

<#
    Workspace copy. Origin: ONTAP\Widelink - DFS\Get-DFSNameSpaceRoot.psm1 — copied in
    2026-07-30 so the DFS cleanup tooling loads nothing from outside Netapp-Code-WorkSpace.
    If the original changes, re-copy; this copy is what the cleanup scripts use.

    One fix applied here: DisplayInBytes is defined below. The original calls it for quota
    formatting but never defines it — it inherited the helper from Na-Module-reports.psm1 when
    run inside the Jenkins reports. Standalone, the call threw, the caller caught the whole
    widelink resolution as "failed", and the target was then wrongly reported as an orphaned
    share. Only qtrees WITH a quota reach that code path, which is why it stayed hidden.
#>

function DisplayInBytes($num) {
    $suffix = 'B', 'KB', 'MB', 'GB', 'TB', 'PB', 'EB', 'ZB', 'YB'
    $index = 0
    while ($num -gt 1kb) { $num = $num / 1kb; $index++ }
    '{0:N2} {1}' -f $num, $suffix[$index]
}

function  connetapp {
    if (!$global:CurrentNcController) {
        # Cluster alias comes from Config_DFSCleanup.json (gitignored). Callers inside this
        # workspace connect before importing, so this is only a fallback for ad-hoc use.
        connect-nccontroller $env:DFS_CLUSTER_ALIAS
    }
}

<#
.SYNOPSIS
    Retrieves information about a specified DFS path.

.DESCRIPTION
    This function queries the root information from a DFS name space on the netapp  and returns details such as share,Volume,UnixPath,vserver,Link,Qtree.

.PARAMETER share
    The name of the share to query.

.PARAMETER Vserver
    The name of the vserver to run the query on.

.EXAMPLE
    PS C:\> Get-DFSNameSpaceRoot "\\<ns>\dfs\<Link>" -Vserver <svm>
    Retrieves information for DFS name space.

.NOTES
    work only if you have saved NC-Credntials before.

#>
function Get-DFSNameSpaceRoot {

    param (
        $share,
        $Vserver
    )
    connetapp
    $share = $share.split('\\').split('\')

    # test if share name is too long
    if ($share.count -gt 5) {
        Write-error "Cant Proccess share with more then 4 namespace keep it to \\servername\dfs\link\qtree"
        break
        exit
    }

    # Handle case where share is like '\\tlvnetapp1\Neumunster_Engineering$'
    if ($share.Count -eq 3 -and $share[2] -match '\$$') {
        $shareName = $share[2]
        try { $nccifsshare = get-nccifsshare -ShareName $shareName -VserverContext $Vserver -ErrorAction Stop } catch {
            throw "Share $shareName not found in vserver $Vserver"
        }
        $path = $nccifsshare.Path
        $Qtree = $path.split('/')[2]
        Write-Host "Share: $shareName" -ForegroundColor Cyan
        Write-Host "Share Path: $path" -ForegroundColor Cyan
        Write-Host "Qtree Path: $Qtree " -ForegroundColor Cyan
        $DFSINFOREPORT = [PSCustomObject] @{Share = $nccifsshare.ShareName ; Volume = $nccifsshare.Volume ; UnixPath = $path ; CifsServer=$nccifsshare.CifsServer ; vserver = $nccifsshare.Vserver; QTREE = $Qtree; }
        return $DFSINFOREPORT
    }

    if ($($share[4])) {
        Write-host "/vol/$($share[2])/$($share[3])/$($share[4]) : this is the path on the Netapp"  -ForegroundColor Blue
    } else {
        Write-host "/vol/$($share[2])/$($share[3]) : this is the path on the Netapp"  -ForegroundColor Blue
    }

    $path1 = "/vol/$($share[2])"
    $path2 = $($share[3])

    # Build the unix path directly from the share component and look up the widelink
    $UnixPath = "/$path2/"

    # get Initial nccifssymlink
    $nccifssymlink = get-nccifssymlink -UnixPath $UnixPath -VserverContext $vserver
    if (!$nccifssymlink) {
        throw "DFS widelink not found for path '$UnixPath' in vserver '$vserver'. Check that '$path2' is a configured CIFS widelink."
    }
    $nccifsshare = get-nccifsshare -ShareName $($nccifssymlink.ShareName) -VserverContext $vserver

    # Set the Qtree last Directory in the Share path
    $qtree = ($share | Select-Object -Last 1)

    if (!(($nccifsshare.Path).GetType().name -eq 'String')) {
       throw  "Path my not exist in vserver $Vserver under:$share"
    }
    # Detect DFS Link
    try {
        $ifshareISaDFS = Read-NcDirectory -VserverContext $nccifsshare.vserver -Path "/vol$($nccifsshare.Path)" -ErrorAction stop | ? { $_.Type -eq "symlink" } | ? { $_.name -eq $qtree }
    }
    catch {
        throw "Error reading DFS link: $_"
    }
    if ($ifshareISaDFS) {
        $NcSymLinkTarget = get-nccifssymlink -UnixPath "/$($ifshareISaDFS.name)/" -VserverContext $Vserver
        $link = "$path1/$path2/$qtree"

    }
    else {
        $link = "$path1/$path2"
        $NcSymLinkTarget = $nccifssymlink
    }
    # get the DFS link Informations
    $nccifsshare = get-nccifsshare -ShareName $NcSymLinkTarget.sharename -VserverContext $Vserver
    $vol = get-ncvol "$($nccifsshare.Path.split('/')[1])" -VserverContext $Vserver
    $Q_Qtree = "$($nccifsshare.Path.split('/')[2])"
    $cifsServer = (Get-NcCifsServer -VserverContext $Vserver).CifsServer
    $node = (Get-NcAggr $vol.Aggregate).Nodes

    # Get quota for the qtree if one exists
    $quotaReport = Get-NcQuotaReport -Volume $vol.Name -VserverContext $Vserver | Where-Object { $_.Qtree -eq $Q_Qtree -and $_.QuotaType -eq "tree" }
    if ($quotaReport -and $quotaReport.DiskLimit -ne "-" -and [long]$quotaReport.DiskLimit -gt 0) {
        $quotaLimit   = DisplayInBytes($quotaReport.DiskLimit)
        $quotaUsed    = DisplayInBytes($quotaReport.DiskUsed)
        $quotaUsedPct = "{0:N1} %" -f ($quotaReport.DiskUsed / $quotaReport.DiskLimit * 100)
    } else {
        $quotaLimit   = $null
        $quotaUsed    = $null
        $quotaUsedPct = $null
    }

    # Create the Report
    $DFSINFOREPORT = [PSCustomObject] @{
        Share         = $NcSymLinkTarget.ShareName
        Volume        = $vol.Name
        UnixPath      = $NcSymLinkTarget.UnixPath
        vserver       = $vol.Vserver
        LINK          = $Link
        QTREE         = $Q_Qtree
        CifsServer    = $cifsServer
        SharePath     = $nccifsshare.Path
        JunctionPath  = $vol.JunctionPath
        Aggregate     = $vol.Aggregate
        Node          = $node
        QuotaLimit    = $quotaLimit
        QuotaUsed     = $quotaUsed
        QuotaUsedPct  = $quotaUsedPct
    }
    return $DFSINFOREPORT
}

Set-Alias -Name Find-DFSPath -Value Get-DFSNameSpaceRoot
Set-Alias -Name Find-DFSRoot -Value Get-DFSNameSpaceRoot
Set-Alias -Name Get-DFSPath -Value Get-DFSNameSpaceRoot
Set-Alias -Name Get-DFSRoot -Value Get-DFSNameSpaceRoot
Set-Alias -Name fdfsroot -Value Get-DFSNameSpaceRoot

# Test Call — supply your own namespace paths and SVM; nothing real is hardcoded here.
function Calltest {
    param(
        [string]$Vserver = $env:DFS_VSERVER,
        [string[]]$Share = @('\\<ns>\dfs\<Link>', '\\<ns>\<share>$\<Sub>')
    )
    connetapp
    $Share | ForEach-Object { fdfsroot $_ -Vserver $Vserver | Format-Table }
}
