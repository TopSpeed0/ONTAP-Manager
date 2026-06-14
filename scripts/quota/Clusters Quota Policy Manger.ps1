# this script will help you to manage quota on netapp cluster
# it will connect to the cluster and get all quota report, and filter the quota that are above a certain percentage, and then allow the user to resize the quota
do {
    try { $percentage = [int](Read-host "What level of Percentage quota you wish to see (must be between 10 and 99)") } catch {}
} while ($percentage -le 10 -or $percentage -ge 100)
$percentage = 100 - $percentage
try {
    # Clean any Netapp Module previously loaded
    Remove-Module NetApp.ONTAP -Force -Confirm:$false -ErrorAction SilentlyContinue 
    Remove-Module DataONTAP -Force -Confirm:$false -ErrorAction SilentlyContinue 
    Remove-Module NetAppDocs -Force -Confirm:$false -ErrorAction SilentlyContinue 
}
catch {}
# import Import-Module DataONTAP / NNetApp.ONTAP
try {
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        if (Get-Module -ListAvailable *Netapp.ONTAP*) { 
            Import-Module NetApp.ONTAP -ErrorAction Stop
            $loaded = 'NetApp.ONTAP'
        } 
    } 
    elseif ($PSVersionTable.PSVersion.Major -eq 5) {
        $PSVersionTable.PSVersion.Major
        if (Get-Module -ListAvailable *DataONTAP*) { 
            Import-Module DataONTAP -ErrorAction Stop
            $loaded = 'DataONTAP'
        }
        elseif (Get-Module -ListAvailable *Netapp.ONTAP*) { 
            Import-Module Netapp.ONTAP -ErrorAction Stop
            $loaded = 'NetApp.ONTAP'
        } 
    }
    else {
        Write-Error "PowerShell Version$($PSVersionTable.PSVersion.Major) Not Supported !"
        break
    }
    if (!$loaded) {
        $NetappONTAP = Find-Module NetApp.ONTAP
        Write-Error  "No Ontap Powershell Tool Kit is install on this system Avilable Module to Download: $($NetappONTAP.Version)_$($NetappONTAP.Name)"

        break
    }
}
catch {
    $ErrorMessage = $_.Exception.Message
    Write-Error  "exiting script becuse we could not load DataONTAP error: $ErrorMessage"
    Pause
}
# Create a function to display sizes (input in bytes - NetApp.ONTAP toolkit returns bytes)
$Target = Read-host "Provide an Qtree name to Resize"
function DisplayInKB($num) {
    $suffix = "B", "KB", "MB", "GB", "TB", "PB", "EB", "ZB", "YB"
    $index = 0
    while ($num -gt 1kb) {
        $num = $num / 1kb
        $index++
    } 

    "{0:N2} {1}" -f $num, $suffix[$index]
}
# Set Netapp Cluster name
$NCCluster = 'cluster-prod'
# set SVM to work with\
$SVM_NAS = 'svm_nas_prod'
$user = $null

# start timeout for connection
$startTime = Get-Date

# Check if we have credentials stored for the Cluster if not ask for them
while ($null -eq $CurrentNcController.name -or $startTime.AddMinutes(5) -lt (Get-Date)) {
    $user = $null
    if ( $null -eq (Get-NcCredential -Name $NCCluster) ) {
        while (($user -notmatch "MyOrg\\") -or ($null -eq $user) -or ($user -ne "root")) {
            $user = read-host "Please use your A_Account must be Member of IT_InfraOps_A | A_Account"
            if ($user -eq "root") {
                Add-NcCredential -Name $NCCluster -Credential (Get-Credential $user ) 
            }
            else {
                if (Get-Module activeDirectory -ListAvailable) {
                    try {
                        Import-Module activeDirectory
                        if ($user -match "MyOrg\\") {
                            $user = $user.Split('\')[1]
                        }
                        get-aduser $user -ErrorAction stop | Out-Null
                        $user = "MyOrg\" + $user
                    }
                    catch {
                        Write-Host "User $user not found in AD please try again provide user name in 'MyOrg\\username' format or just username" -ForegroundColor Red
                        $user = $null
                    }
                }
                else {
                    $user = "MyOrg\" + $user
                }
                # Store the Credentials for the Cluster
                Add-NcCredential -Name $NCCluster -Credential (Get-Credential $user ) 
            }
        }
    }
    try {
        Connect-NcController -Name $NCCluster -ErrorAction Stop | Out-Null
    }
    catch {
        $ErrorMessage = $_.Exception.Message
        Write-Error  "Please provide correct credentials for $NCCluster"
        Get-NcCredential -Name $NCCluster | Remove-NcCredential -ErrorAction SilentlyContinue
        Pause
    }
}
if ($startTime.AddMinutes(5) -lt (Get-Date) ) {
    Write-Error "Could not connect to $NCCluster after 5 minutes, exiting script"
    break
    exit
    throw 1
}
#exit # here for testing for now
$GetNcQuotaReport = Get-NcQuotaReport 
$GetNcQuotaReport_filterd = @()
foreach ($NcQuota in $GetNcQuotaReport) {
    $NcQuotaDiskLimit = $NcQuota.DiskLimit
    $NcQuotaDiskUsed = $NcQuota.DiskUsed
    if ($NcQuotaDiskLimit -ne "-" -and [long]$NcQuotaDiskLimit -gt 0) {
        $DifferenceCount = $NcQuotaDiskLimit - $NcQuotaDiskUsed + 1
        $percentageDifference = $DifferenceCount / $NcQuotaDiskLimit * 100
    
        if ($percentageDifference -lt $percentage) {
            $percentageUsed = "{0:N1}" -f (100 - $percentageDifference)
            #Write-Output "$($NcQuota.Tree) is at $percentageUsed % is using DiskUsed: $(DisplayInKB($($NcQuota.DiskUsed))) outof $(DisplayInKB($($NcQuota.DiskLimit)))"
            $NcQuota | Add-Member -MemberType NoteProperty -Name "PercentageUsed" -Value "$percentageUsed %"
            $GetNcQuotaReport_filterd += $NcQuota
    
        }
    }
}

 $GetNcQuotaReport_filterd_temp = $GetNcQuotaReport_filterd | Select-Object Volume, Qtree, @{ Label = "DiskLimit" ;
    Expression = { if ($_.DiskLimit -and $_.DiskLimit -ne "-" -and [long]$_.DiskLimit -gt 0) { DisplayInKB($_.DiskLimit) } else { "-" } }
}, @{ Label    = "DiskUsed" ;
    Expression = { if ($_.DiskUsed -and $_.DiskUsed -ne "-" -and [long]$_.DiskUsed -gt 0) { DisplayInKB($_.DiskUsed) } else { "-" } }
}, @{ Label    = "SoftDiskLimit" ;
    Expression = { if ($_.SoftDiskLimit -and $_.SoftDiskLimit -ne "-" -and [long]$_.SoftDiskLimit -gt 0) { DisplayInKB($_.SoftDiskLimit) } else { "-" } }
}, PercentageUsed, Vserver

$GetNcQuotaReport_filterd = $GetNcQuotaReport_filterd_temp
write-host "Extra Info: all Qtrees that are above $percentage% used marked for review" -ForegroundColor Blue
write-host "beside the Qtree name you will see the percentage used" -ForegroundColor Blue
if ([string]::IsNullOrWhiteSpace($Target)) {
    $NcQuota = $GetNcQuotaReport_filterd | Out-GridView -PassThru -Title "Select the Qtree you want to Resize"
} else {
    # $NcQuota = $GetNcQuotaReport_filterd | ? { $_.Qtree -match $Target } | Out-GridView -PassThru -Title "Select the Qtree you want to Resize"
    $NcQuota = $GetNcQuotaReport_filterd | ? { $_.Qtree -match $Target } 
}
$NcQuotaReport = @()
foreach ( $Quota in $NcQuota) {
    # $NcQuotaReport += Get-NcQuota -Qtree NPI_Projects_and_Proposals_Q -Volume general1 -Target "$($Quota.Volume)/$($Quota.Qtree)"
    $NcQuotaReport += Get-NcQuota -Qtree $Quota.Qtree -Volume $Quota.Volume -Target "/vol/$($Quota.Volume)/$($Quota.Qtree)"
}
$NcQuota = $NcQuotaReport
if ($null -eq $NcQuota ) { break }

# Show Quota Configuration for the Target
Write-host "Show Quota Configuration for the Target" -ForegroundColor Green
$SelectedQtreeNames = @($NcQuota | ForEach-Object { $_.Qtree })
$GetNcQuotaReport_filterd | Where-Object { $SelectedQtreeNames -contains $_.Qtree } | Format-Table -AutoSize

foreach ( $Quota in $NcQuota) {
    $QuotaTarget =  "/vol/$($Quota.Volume)/$($Quota.Qtree)"
    Write-host "setting Quota Target:$QuotaTarget if size is grater then 1024 gb use tb less use gb"
    do {   
        $DiskLimit = ((read-host "DiskLimit gb/tb"))
        $SoftDiskLimit = ((read-host "SoftDiskLimit xxx gb/tb"))
        if (($DiskLimit -match "tb") -or ($DiskLimit -match "gb")) {
            $DiskLimit = [Math]::Round([Math]::Ceiling($DiskLimit ) / 1gb)
            $flagDiskLimit = "successfully"
        }
        else {
            Write-Host "set a correct size DiskLimit"
            $flagDiskLimit = "faild"
        }
        if (($SoftDiskLimit -match "tb") -or ($SoftDiskLimit -match "gb")) {
            $SoftDiskLimit = [Math]::Round([Math]::Ceiling($SoftDiskLimit ) / 1gb)
            $flagSoftDiskLimit = "successfully"
        }
        else {
            Write-Host "set a correct size SoftDiskLimit"
            $flagSoftDiskLimit = "faild"
            
        }
    } until (($flagDiskLimit -eq "successfully") -and ($flagSoftDiskLimit -eq "successfully"))

    # calling the Settings
    write-host "you set DiskLimit: $DiskLimit (GB) SoftDiskLimit: $SoftDiskLimit (GB)" -ForegroundColor Green
    Pause

    # setting the qouta
    try {
        # Set-NcQuota -DiskLimit "$($DiskLimit)gb" -SoftDiskLimit "$($SoftDiskLimit)gb" -VserverContext $Quota.Vserver -Qtree $Quota.Qtree -Volume $Quota.Volume -Group ""
        write-host "will set Quota for Volume:$($Quota.Volume) Qtree:$($Quota.Qtree) with DiskLimit: $DiskLimit (GB) SoftDiskLimit: $SoftDiskLimit (GB)" -ForegroundColor Yellow
        $Quota.QuotaTarget = $QuotaTarget
        $SetNcQuotaResult = $Quota | Set-NcQuota -DiskLimit "$($DiskLimit)gb" -SoftDiskLimit "$($SoftDiskLimit)gb" -ErrorAction Stop -Verbose
        $SetNcQuotaResult | Format-Table -AutoSize
    }
    catch {
        $SetNcQuota = $PSItem.Exception.Message
        Write-Error $SetNcQuota
    }
    finally {
        if (!$SetNcQuota) {
            write-host "Successfully set  Quota Volume:$($Quota.Volume) Qtree:$($Quota.Qtree)" -ForegroundColor Yellow | Out-Null
        }
    }
    if (!$SetNcQuota) {
        # Start the Resize
        try {
            Start-NcQuotaResize -VserverContext $Quota.Vserver -Volume $Quota.Volume -ErrorAction Stop -Verbose
        }
        catch {
            $StartNcQuotaResize = $PSItem.Exception.Message
            Write-Error $StartNcQuotaResize
            # Auto-recovery: disable and re-enable quotas on the volume, then retry
            write-host "Attempting auto-recovery: Disable/Enable quotas on Volume:$($Quota.Volume)..." -ForegroundColor Cyan
            try {
                Disable-NcQuota -VserverContext $Quota.Vserver -Volume $Quota.Volume -ErrorAction Stop -Verbose
                Enable-NcQuota -VserverContext $Quota.Vserver -Volume $Quota.Volume -ErrorAction Stop -Verbose
                write-host "Successfully recovered quotas on Volume:$($Quota.Volume) Qtree:$($Quota.Qtree)" -ForegroundColor Yellow
                $StartNcQuotaResize = $null
            }
            catch {
                Write-Error "Auto-recovery failed: $($PSItem.Exception.Message)"
            }
        }
        finally {
            if (!$StartNcQuotaResize) {
                write-host "Successfully Resize Quota:$($Quota.Volume) Qtree:$($Quota.Qtree)"  -ForegroundColor Yellow
            }
        }
    }
    $StartNcQuotaResize = $null
    $SetNcQuota = $null
}

# Show updated Quota Report after all changes
write-host "Refreshing Quota Report..." -ForegroundColor Cyan
$GetNcQuotaReport = Get-NcQuotaReport 
$GetNcQuotaReport_updated = @()
foreach ($Quota in $NcQuotaReport) {
    foreach ($report in $GetNcQuotaReport) {
        if ($report.Qtree -eq $Quota.Qtree -and $report.Volume -eq $Quota.Volume) {
            $NcQuotaDiskLimit = $report.DiskLimit
            $NcQuotaDiskUsed = $report.DiskUsed
            if ($NcQuotaDiskLimit -ne "-" -and [long]$NcQuotaDiskLimit -gt 0) {
                $DifferenceCount = $NcQuotaDiskLimit - $NcQuotaDiskUsed + 1
                $percentageDifference = $DifferenceCount / $NcQuotaDiskLimit * 100
                $percentageUsed = "{0:N1}" -f (100 - $percentageDifference)
                $report | Add-Member -MemberType NoteProperty -Name "PercentageUsed" -Value "$percentageUsed %" -Force
                $GetNcQuotaReport_updated += $report
            }
        }
    }
}

$GetNcQuotaReport_updated = $GetNcQuotaReport_updated | Select-Object Volume, Qtree, @{ Label = "DiskLimit" ;
    Expression = { if ($_.DiskLimit -and $_.DiskLimit -ne "-" -and [long]$_.DiskLimit -gt 0) { DisplayInKB($_.DiskLimit) } else { "-" } }
}, @{ Label    = "DiskUsed" ;
    Expression = { if ($_.DiskUsed -and $_.DiskUsed -ne "-" -and [long]$_.DiskUsed -gt 0) { DisplayInKB($_.DiskUsed) } else { "-" } }
}, @{ Label    = "SoftDiskLimit" ;
    Expression = { if ($_.SoftDiskLimit -and $_.SoftDiskLimit -ne "-" -and [long]$_.SoftDiskLimit -gt 0) { DisplayInKB($_.SoftDiskLimit) } else { "-" } }
}, PercentageUsed, Vserver

write-host "Updated Quota Report for modified Qtrees:" -ForegroundColor Green
$GetNcQuotaReport_updated | Format-Table -AutoSize
