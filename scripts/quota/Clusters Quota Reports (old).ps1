#Requires -Version 7.0 

Import-Module NetApp.ONTAP -ErrorAction SilentlyContinue

# Create a function to clculate the raw size data per KB
#Qtree Qouta 
# Deployment_Q
$Target = Read-host "Provide an Qtree name to Resize"
function DisplayInKB($num) {
    $suffix = "KB", "MB", "GB", "TB", "PB", "EB", "ZB", "YB"
    $index = 0
    while ($num -gt 1kb) {
        $num = $num / 1kb
        $index++
    } 

    "{0:N2} {1}" -f $num, $suffix[$index]
}

#TLV HRZ
if ( $null -eq (Get-NcCredential -Name cluster-prod) ) { Add-NcCredential -Name cluster-prod -Credential (Get-Credential -Message "Please use your memmger of MYORG\IT_InfraOps_A Domain use" ) }
Connect-NcController -Name cluster-prod

$GetNcQuotaReport = Get-NcQuotaReport 
$GetNcQuotaReport_filterd = @()
foreach ($NcQuota in $GetNcQuotaReport) {
    $NcQuotaDiskLimit = $NcQuota.DiskLimit
    $NcQuotaDiskUsed = $NcQuota.DiskUsed
    $DifferenceCount = $NcQuotaDiskLimit - $NcQuotaDiskUsed + 1
    $percentageDifference = $DifferenceCount / $NcQuotaDiskLimit * 100

    if ($percentageDifference -lt 6) {
        $percentageUsed = "{0:N1}" -f (100 - $percentageDifference)
        #Write-Output "$($NcQuota.Tree) is at $percentageUsed % is using DiskUsed: $(DisplayInKB($($NcQuota.DiskUsed))) outof $(DisplayInKB($($NcQuota.DiskLimit)))"
        $NcQuota | Add-Member -MemberType NoteProperty -Name "PercentageUsed" -Value "$percentageUsed %"
        $GetNcQuotaReport_filterd += $NcQuota

    }
}

$GetNcQuotaReport_filterd = $GetNcQuotaReport_filterd | Select-Object QuotaTarget, Volume, Qtree, @{ Label = "DiskLimit" ;
    Expression = { "{0:N0}" -f (DisplayInKB($_.DiskLimit)) }
}, @{ Label    = "DiskUsed" ;
    Expression = { "{0:N0}" -f (DisplayInKB($_.DiskUsed)) }
}, @{ Label    = "SoftDiskLimit" ;
    Expression = { "{0:N0}" -f (DisplayInKB($_.SoftDiskLimit)) }
}, PercentageUsed, Vserver
$GetNcQuotaReport_filterd | ft
Pause



#Set The Target
if (![string]::IsNullOrEmpty($Target)) { 
    $NcQuota = Get-NcQuota -Vserver svm_nas -Target "*$($Target)*" 

# Show Quota Configuration for the Target
Write-host "Show Quota Configuration for the Target: $Target" -ForegroundColor Green

$NcQuota | Select-Object @{ Label = "DiskLimit" ;
    Expression = { "{0:N0}" -f (DisplayInKB($_.DiskLimit)) }
}, @{ Label    = "SoftDiskLimit" ;
    Expression = { "{0:N0}" -f (DisplayInKB($_.SoftDiskLimit)) }
},  Vserver,Volume,Qtree,QuotaTarget | ft

# Show the Curent Status of the Quota Report for the Target
Write-host "Show the Curent Status of the Quota Report for the Target: $Target" -ForegroundColor Green
$NcQuotaReportTarget = Get-NcQuotaReport -Vserver svm_nas -Target "*$($Target)*" 

$NcQuota = $null
$GetNcQuotaReport = $NcQuotaReportTarget 
$GetNcQuotaReport_filterd = @()
foreach ($NcQuota in $GetNcQuotaReport) {
    $NcQuotaDiskLimit = $NcQuota.DiskLimit
    $NcQuotaDiskUsed = $NcQuota.DiskUsed
    $DifferenceCount = $NcQuotaDiskLimit - $NcQuotaDiskUsed + 1
    $percentageDifference = $DifferenceCount / $NcQuotaDiskLimit * 100

    $percentageUsed = "{0:N1}" -f (100 - $percentageDifference)
    #Write-Output "$($NcQuota.Tree) is at $percentageUsed % is using DiskUsed: $(DisplayInKB($($NcQuota.DiskUsed))) outof $(DisplayInKB($($NcQuota.DiskLimit)))"
    $NcQuota | Add-Member -MemberType NoteProperty -Name "PercentageUsed" -Value "$percentageUsed %"
    $GetNcQuotaReport_filterd += $NcQuota
  
}

$GetNcQuotaReport_filterd = $GetNcQuotaReport_filterd | Select-Object QuotaTarget, Volume, Qtree, @{ Label = "DiskLimit" ;
    Expression = { "{0:N0}" -f (DisplayInKB($_.DiskLimit)) }
}, @{ Label    = "DiskUsed" ;
    Expression = { "{0:N0}" -f (DisplayInKB($_.DiskUsed)) }
}, @{ Label    = "SoftDiskLimit" ;
    Expression = { "{0:N0}" -f (DisplayInKB($_.SoftDiskLimit)) }
}, PercentageUsed, Vserver
$GetNcQuotaReport_filterd | ft -AutoSize 


foreach ( $Quota in $NcQuota) {
Write-host "setting Quota for  $Quota if size is grater then 1024 gb use tb less use gb"
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
    write-host "you set DiskLimit: $DiskLimit (GB) SoftDiskLimit: $SoftDiskLimit (GB) "  -ForegroundColor Green
    Pause
    # setting the qouta
    Set-NcQuota  -DiskLimit "$($DiskLimit)gb" -SoftDiskLimit "$($SoftDiskLimit)gb"  -Path $Quota.QuotaTarget -VserverContext $Quota.Vserver
    # Start the Resize
    write-host "Starting the Resize on Volume: $($Quota.Volume) Qtree: $($Quota.Qtree)"  -ForegroundColor Yellow
    Pause
    Start-NcQuotaResize -VserverContext $Quota.Vserver -Volume $Quota.Volume | Out-Null
	Pause
}
} else {
    # 
    Write-host "Qree not provided" -ForegroundColor Green
    $NcQuota = Get-NcQuota -Vserver svm_nas -Target "*"

# Show Quota Configuration for the Target
Write-host "Show Quota Configuration for the Target: *" -ForegroundColor Green
Pause

$NcQuota | Select-Object @{ Label = "DiskLimit" ;
    Expression = { "{0:N0}" -f (DisplayInKB($_.DiskLimit)) }
}, @{ Label    = "SoftDiskLimit" ;
    Expression = { "{0:N0}" -f (DisplayInKB($_.SoftDiskLimit)) }
},  Vserver,Volume,Qtree,QuotaTarget | ft

# Show the Curent Status of the Quota Report for the Target
Write-host "Show the Curent Status of the Quota Report for the Target:*" -ForegroundColor Green
Pause
$NcQuotaReportTarget = Get-NcQuotaReport -Vserver svm_nas -Target "*" 

$NcQuota = $null
$GetNcQuotaReport = $NcQuotaReportTarget 
$GetNcQuotaReport_filterd = @()
foreach ($NcQuota in $GetNcQuotaReport) {
    $NcQuotaDiskLimit = $NcQuota.DiskLimit
    $NcQuotaDiskUsed = $NcQuota.DiskUsed
    $DifferenceCount = $NcQuotaDiskLimit - $NcQuotaDiskUsed + 1
    $percentageDifference = $DifferenceCount / $NcQuotaDiskLimit * 100

    $percentageUsed = "{0:N1}" -f (100 - $percentageDifference)
    #Write-Output "$($NcQuota.Tree) is at $percentageUsed % is using DiskUsed: $(DisplayInKB($($NcQuota.DiskUsed))) outof $(DisplayInKB($($NcQuota.DiskLimit)))"
    $NcQuota | Add-Member -MemberType NoteProperty -Name "PercentageUsed" -Value "$percentageUsed %"
    $GetNcQuotaReport_filterd += $NcQuota
  
}

$GetNcQuotaReport_filterd = $GetNcQuotaReport_filterd | Select-Object QuotaTarget, Volume, Qtree, @{ Label = "DiskLimit" ;
    Expression = { "{0:N0}" -f (DisplayInKB($_.DiskLimit)) }
}, @{ Label    = "DiskUsed" ;
    Expression = { "{0:N0}" -f (DisplayInKB($_.DiskUsed)) }
}, @{ Label    = "SoftDiskLimit" ;
    Expression = { "{0:N0}" -f (DisplayInKB($_.SoftDiskLimit)) }
}, PercentageUsed, Vserver
$GetNcQuotaReport_filterd | ft -AutoSize 

}
# Qouta errors show
#Get-NcQuotaReport
#Get-NcQuotaStatus | ? { !($_.QuotaErrorMsgs -eq $null)}