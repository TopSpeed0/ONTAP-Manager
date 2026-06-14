# Monitor-SnapMirror.ps1
# Periodically checks SnapMirror status on a cluster and sends report
# Usage: .\Monitor-SnapMirror.ps1 -ClusterName "cluster-dr"

param(
    [Parameter(Mandatory=$true)]
    [string]$ClusterName,
    [int]$IntervalHours = 3
)

$rootDir = (Resolve-Path "$PSScriptRoot\..\..").Path
. "$rootDir\Load-Config.ps1"

# Resolve cluster from config
$clEntry = $ONTAP_Clusters | Where-Object { $_.ClusterName -eq $ClusterName -or $_.ConnectName -eq $ClusterName }
if (-not $clEntry) {
    $available = ($ONTAP_Clusters | ForEach-Object { $_.ClusterName }) -join ', '
    throw "Unknown cluster '$ClusterName'. Available: $available"
}
$sshHost = if ($clEntry.FallbackIP) { $clEntry.FallbackIP } else { $clEntry.ConnectName }

function Get-SmStatus {
    $raw = ssh "admin@$sshHost" 'set -privilege diagnostic -confirmations off; rows 0; set -showseparator ","; snapmirror show -fields source-path,destination-path,state,status,last-transfer-end-timestamp,last-transfer-size,last-transfer-error,lag-time'
    $lines = $raw | Where-Object {
        $_ -match ',' -and
        $_ -notmatch 'Last login' -and
        $_ -notmatch 'entries were displayed' -and
        $_ -notmatch 'WARNING' -and
        $_ -notmatch '^\s*$'
    } | ForEach-Object { $_.TrimEnd(',').Trim() }

    if ($lines.Count -ge 3) {
        return $lines[1..($lines.Count-1)] | ConvertFrom-Csv
    }
    return @()
}

function Format-SmReport {
    param($Data)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm"
    $report = "📊 **SnapMirror Status — $($clEntry.ClusterName)** ($timestamp)`n`n"

    # Summary
    $byStatus = $Data | Group-Object 'Relationship Status'
    $statusLine = ($byStatus | ForEach-Object { "$($_.Name): $($_.Count)" }) -join " | "
    $report += "**Summary:** $($Data.Count) relationships — $statusLine`n`n"

    # Errors section
    $withErrors = $Data | Where-Object { $_.'Last Transfer Error' -and $_.'Last Transfer Error' -ne '-' -and $_.'Last Transfer Error' -ne '' }
    if ($withErrors) {
        $report += "❌ **Relationships with Transfer Errors ($($withErrors.Count)):**`n"
        foreach ($r in $withErrors) {
            $report += "• ``$($r.'Destination Path')```n"
            $report += "  Status: $($r.'Relationship Status') | Last Transfer: $($r.'Last Transfer End Timestamp')`n"
            $report += "  Error: $($r.'Last Transfer Error')`n`n"
        }
    } else {
        $report += "✅ **No transfer errors**`n`n"
    }

    # Still transferring
    $transferring = $Data | Where-Object { $_.'Relationship Status' -eq 'Transferring' }
    if ($transferring) {
        $report += "🔄 **Currently Transferring ($($transferring.Count)):**`n"
        foreach ($r in $transferring) {
            $report += "• ``$($r.'Destination Path')`` — lag: $($r.'Lag Time')`n"
        }
        $report += "`n"
    }

    # Idle with lag > 24h (potential concern)
    $idle = $Data | Where-Object { $_.'Relationship Status' -eq 'Idle' }
    if ($idle) {
        $report += "⏸️ **Idle ($($idle.Count)):**`n"
        foreach ($r in $idle) {
            $lagFlag = ""
            if ($r.'Lag Time' -match '(\d+):(\d+):(\d+)') {
                $lagHours = [int]$Matches[1]
                if ($lagHours -ge 24) { $lagFlag = " ⚠️ HIGH LAG" }
            }
            $report += "• ``$($r.'Destination Path')`` — lag: $($r.'Lag Time') | last: $($r.'Last Transfer End Timestamp') | size: $($r.'Last Transfer Size')$lagFlag`n"
        }
        $report += "`n"
    }

    # InSync
    $insync = $Data | Where-Object { $_.'Relationship Status' -eq 'InSync' }
    if ($insync) {
        $report += "🟢 **In-Sync ($($insync.Count)):**`n"
        foreach ($r in $insync) {
            $report += "• ``$($r.'Destination Path')```n"
        }
    }

    return $report
}

# Main loop
Write-Host "SnapMirror Monitor started. Reporting every $IntervalHours hours." -ForegroundColor Green
Write-Host "Press Ctrl+C to stop." -ForegroundColor Yellow
Write-Host ""

$iteration = 0
while ($true) {
    $iteration++
    $now = Get-Date -Format "HH:mm:ss"
    Write-Host "[$now] Iteration $iteration — Querying cluster-dr..." -ForegroundColor Cyan

    try {
        $smData = Get-SmStatus
        if ($smData.Count -gt 0) {
            $report = Format-SmReport -Data $smData
            Write-Host "[$now] Sending report ($($smData.Count) relationships)..." -ForegroundColor Cyan

            # Send via Telegram - using the MCP notify function through PowerShell isn't possible directly.
            # Instead, save to file and print so the agent can read it.
            $report | Out-File -FilePath "$PSScriptRoot\snapmirror-status.txt" -Encoding utf8 -Force
            Write-Host $report
            Write-Host "---REPORT_READY---"
        } else {
            Write-Host "[$now] WARNING: No data returned from cluster-dr" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "[$now] ERROR: $_" -ForegroundColor Red
    }

    if ($iteration -eq 1) {
        Write-Host "[$now] First report done. Next in $IntervalHours hours." -ForegroundColor Green
    }
    Start-Sleep -Seconds ($IntervalHours * 3600)
}
