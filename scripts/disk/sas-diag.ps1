# Load config for cluster definitions
$_sasRootDir = (Resolve-Path "$PSScriptRoot\..\..").Path
. "$_sasRootDir\Load-Config.ps1"

function Get-SasDiag {
<#
.SYNOPSIS
    SAS / disk / shelf connectivity diagnostics for any ONTAP cluster.
.DESCRIPTION
    Runs 11 diagnostic checks via SSH. Cluster list loaded from config.json.
    Accepts a cluster name and resolves it to the SSH host.
    Verifies SSH connectivity before running diagnostics.
.EXAMPLE
    Get-SasDiag Netapp-Cluster
.EXAMPLE
    Get-SasDiag Netapp-Cluster -Shelf 1
.EXAMPLE
    Get-SasDiag Netapp-Cluster -Export
.EXAMPLE
    Get-SasDiag Netapp-Cluster -Json
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [string]$Cluster,

        [Parameter(Mandatory=$false)]
        [int]$Shelf,

        [switch]$Export,

        [switch]$Json
    )

    # ── Resolve cluster from config.json ──────────────────────────────────
    $clEntry = $ONTAP_Clusters | Where-Object { $_.ClusterName -eq $Cluster -or $_.ConnectName -eq $Cluster }
    if (-not $clEntry) {
        $available = ($ONTAP_Clusters | ForEach-Object { $_.ClusterName }) -join ', '
        Write-Host "Unknown cluster '$Cluster'. Available: $available" -ForegroundColor Red
        return
    }
    $sshHost = if ($clEntry.FallbackIP) { $clEntry.FallbackIP } else { $clEntry.ConnectName }

    # ── Verify / establish SSH connectivity ───────────────────────────────
    Write-Host "Testing SSH to admin@$sshHost ..." -ForegroundColor Gray
    $test = ssh -o ConnectTimeout=5 -o BatchMode=yes "admin@$sshHost" "version" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "SSH to admin@$sshHost FAILED — check network / SSH keys." -ForegroundColor Red
        Write-Host $test -ForegroundColor Red
        return
    }
    Write-Host "Connected: $($test | Select-Object -First 1)" -ForegroundColor Green

    # Run a single ONTAP CLI command via SSH
    function Invoke-Cmd ([string]$Cmd) { ssh "admin@$sshHost" $Cmd 2>$null }

    # Run an ONTAP CLI command with CSV parsing (for -Json mode)
    # Uses '|' as separator — only works with '-fields' commands
    function Invoke-CsvCmd ([string]$Cmd) {
        $wrapped = "set diagnostic -confirmations off -showseparator '|' ; row 0 ; $Cmd"
        $raw = ssh "admin@$sshHost" $wrapped 2>$null
        # Skip ONTAP banner lines, strip single-quotes, filter noise, parse as '|'-delimited
        $lines = $raw | Select-Object -Skip 8 | ForEach-Object { $_ -replace "'","" } |
                 Where-Object {
                     $_ -match '\S' -and
                     $_ -notmatch '^\d+ entries were displayed' -and
                     $_ -notmatch '^Last login time:' -and
                     $_ -notmatch '^Error:' -and
                     $_ -notmatch 'no entries matching' -and
                     $_ -notmatch '^Info:' -and
                     $_ -notmatch '^\s+capacity use' -and
                     $_ -notmatch '^This table is currently empty'
                 }
        if ($lines) { $lines | ConvertFrom-Csv -Delimiter '|' -ErrorAction SilentlyContinue }
    }

    # Collect results for CSV export
    $results = [System.Collections.Generic.List[PSCustomObject]]::()
    # Collect structured results for JSON export
    $jsonData = [ordered]@{
        Cluster   = $Cluster
        Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Checks    = [ordered]@{}
    }

    # $IsFieldsCmd — true if command uses -fields (CSV-parseable), false for table output
    function Run-Check ([int]$Step, [string]$Name, [string]$Cmd) {
        Write-Host "── $Step. $Name ──" -ForegroundColor Yellow
        $output = Invoke-Cmd $Cmd
        $output
        Write-Host ""
        if ($Export) {
            ($output | Where-Object { $_ -match '\S' }) | ForEach-Object {
                $results.Add([PSCustomObject]@{
                    Cluster = $Cluster
                    Step    = $Step
                    Check   = $Name
                    Output  = $_
                })
            }
        }
        if ($Json) {
            $key = "{0:D2}_{1}" -f $Step, ($Name -replace '[^a-zA-Z0-9]','_')
            if ($Cmd -match '-fields\s') {
                # -fields commands produce pipe-delimited CSV via showseparator
                $parsed = Invoke-CsvCmd $Cmd
                if ($parsed) {
                    $jsonData.Checks[$key] = @($parsed | ForEach-Object {
                        $obj = [ordered]@{}
                        $_.PSObject.Properties | ForEach-Object { $obj[$_.Name] = $_.Value }
                        $obj
                    })
                } else {
                    $jsonData.Checks[$key] = @()
                }
            } else {
                # Non-fields commands (table output) — store cleaned text lines
                $cleaned = $output | Where-Object {
                    $_ -match '\S' -and
                    $_ -notmatch '^Last login time:' -and
                    $_ -notmatch '^\d+ entries were displayed' -and
                    $_ -notmatch '^This table is currently empty' -and
                    $_ -notmatch '^$'
                }
                $jsonData.Checks[$key] = @(if ($cleaned) { $cleaned } else { @() })
            }
        }
    }

    Write-Host "`n======================================" -ForegroundColor Cyan
    Write-Host "  SAS DIAGNOSTICS — $Cluster" -ForegroundColor Cyan
    Write-Host "======================================`n" -ForegroundColor Cyan

    # ── 1. Storage disk show (path info) ─────────────────────────────────────
    Run-Check 1 "Storage Disk Paths" "storage disk show -fields disk,owner,container-type,shelf,bay"

    # ── 2. SAS port status per node ──────────────────────────────────────────
    Run-Check 2 "SAS Port Status" "storage port show"

    # ── 3. Shelf IOM / module health ─────────────────────────────────────────
    Run-Check 3 "Shelf IOM Module Health" "storage shelf show -fields shelf-id,state,module-type,vendor,module-fw-rev"

    # ── 4. Single-path disks ─────────────────────────────────────────────────
    Run-Check 4 "Single-Path Disks" "storage disk show -fields disk,owner,container-type,shelf,bay"

    # ── 5. Broken / failed disks ─────────────────────────────────────────────
    Run-Check 5 "Broken / Failed Disks" "storage disk show -container-type broken -fields disk,owner,shelf,bay"

    # ── 6. EMS events — SAS/shelf related (last 7 days) ─────────────────────
    Run-Check 6 "EMS Events — SAS" "event log show -severity ERROR -message-name *sas* -fields time,node,message-name,event"
    Write-Host "  [shelf/iom/path events]" -ForegroundColor Gray
    Run-Check 6 "EMS Events — Shelf" "event log show -severity ERROR -message-name *shelf* -fields time,node,message-name,event"
    Run-Check 6 "EMS Events — IOM" "event log show -severity ERROR -message-name *iom* -fields time,node,message-name,event"

    # ── 7. Active system faults ──────────────────────────────────────────────
    Run-Check 7 "Active System Faults" "system health alert show"

    # ── 8. SAS cable / connectivity errors ───────────────────────────────────
    Run-Check 8 "SAS Error Counters" "storage errors show"

    # ── 9. Disk path detail for specific shelf ───────────────────────────────
    if ($Shelf) {
        Run-Check 9 "Disk Path Detail — Shelf $Shelf" "storage disk show -shelf $Shelf -fields disk,shelf,bay,owner,container-type"
    } else {
        Run-Check 9 "Disk Path Detail — All Shelves" "storage disk show -fields disk,shelf,bay,owner,container-type"
    }

    # ── 10. Node hardware status ─────────────────────────────────────────────
    Run-Check 10 "Node HW Status" "system health status show"
    Run-Check 10 "Subsystem Status" "system health subsystem show"

    # ── 11. Shelf port / connectivity info ───────────────────────────────────
    Run-Check 11 "Shelf Port Detail" "storage shelf port show"

    # ── Export to CSV ────────────────────────────────────────────────────────
    if ($Export) {
        $csvPath = Join-Path (Get-Location) "${Cluster}_SAS_diag.csv"
        $results | Export-Csv -Path $csvPath -NoTypeInformation -Force -Encoding UTF8
        Write-Host "Exported $($results.Count) rows → $csvPath" -ForegroundColor Green
    }

    # ── Export to JSON (structured, parsed) ───────────────────────────────
    if ($Json) {
        $jsonPath = Join-Path (Get-Location) "${Cluster}_SAS_diag.json"
        $jsonData | ConvertTo-Json -Depth 10 | Set-Content -Path $jsonPath -Force -Encoding UTF8
        $checkCount = $jsonData.Checks.Count
        Write-Host "Exported $checkCount checks → $jsonPath" -ForegroundColor Green
    }
    Write-Host ""

    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host "  DONE — $Cluster" -ForegroundColor Green
    Write-Host "======================================`n" -ForegroundColor Cyan
}
