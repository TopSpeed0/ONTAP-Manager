---
name: quota-management
description: 'Manage NetApp ONTAP quota policies on qtrees. Use when: viewing quota usage, resizing qtree quotas, quota report, quota percentage used, DiskLimit, SoftDiskLimit, Set-NcQuota, Get-NcQuotaReport, Start-NcQuotaResize, quota resize failed, quota auto-recovery.'
argument-hint: 'Specify qtree name or operation (report, resize)'
---

# Quota Management

## When to Use
- Viewing quota usage reports (which qtrees are near capacity)
- Resizing qtree quotas (DiskLimit, SoftDiskLimit)
- Troubleshooting quota resize failures
- Checking quota status across volumes

## Key Concepts
- **Tree-type quotas**: `QuotaTarget` is often empty — use `Qtree` property instead
- **QuotaTarget format**: `/vol/<Volume>/<Qtree>` — must be set before piping to `Set-NcQuota`
- **Set-NcQuota** requires non-null `-Target` — set `$Quota.QuotaTarget = "/vol/<Vol>/<Qtree>"` before piping
- **Set-NcQuota** returns objects to pipeline — capture in a variable or it leaks output
- `-Path` parameter is unreliable for tree quotas — always set QuotaTarget directly
- **Start-NcQuotaResize** can fail with an internal error — known bug, requires disable/re-enable quotas as workaround

## Gotchas & Lessons Learned
- Offline volumes (State != online) report 0 bytes = 100% used — filter them out
- NetApp UI rounds TiB values — check the edit dialog for precise values
- `Start-NcQuotaResize` internal error → auto-recovery: `Disable-NcQuota` then `Enable-NcQuota` on the volume

## Procedure

### Step 0 — Gather Requirements
Ask the user:
1. **Cluster** (<cluster-name> or <cluster-name>)
2. **SVM** (default: `<svm-name>` on <cluster-name>)
3. **Operation**: report (view usage) or resize (change limits)
4. For resize: qtree name(s), new DiskLimit, new SoftDiskLimit

### View Quota Report (all qtrees above threshold)
```powershell
# Connect to cluster
<alias>  # or: Connect-NcController -Name <cluster-name>

# Get full quota report
$report = Get-NcQuotaReport

# Filter by percentage used (e.g., > 90%)
$threshold = 90
$report | ForEach-Object {
    if ($_.DiskLimit -ne "-" -and [long]$_.DiskLimit -gt 0) {
        $pctUsed = ($_.DiskUsed / $_.DiskLimit) * 100
        if ($pctUsed -ge $threshold) {
            $_ | Add-Member -MemberType NoteProperty -Name PercentageUsed -Value ("{0:N1}%" -f $pctUsed) -Force
            $_
        }
    }
} | Select-Object Volume, Qtree, Vserver,
    @{L='DiskLimit'; E={DisplayInKB $_.DiskLimit}},
    @{L='DiskUsed'; E={DisplayInKB $_.DiskUsed}},
    @{L='SoftDiskLimit'; E={DisplayInKB $_.SoftDiskLimit}},
    PercentageUsed | Format-Table -AutoSize
```

### View Quota for Specific Qtree
```powershell
Get-NcQuota -Vserver <svm-name> -Qtree <qtree_name> -Volume <volume>
Get-NcQuotaReport -Vserver <svm-name> -Qtree <qtree_name>
```

### Resize a Qtree Quota
```powershell
# 1. Get the quota object
$quota = Get-NcQuota -Vserver <svm-name> -Qtree <qtree_name> -Volume <volume> -Target "/vol/<volume>/<qtree>"

# 2. Set the QuotaTarget (REQUIRED — must not be null)
$quota.QuotaTarget = "/vol/<volume>/<qtree>"

# 3. Apply new limits (capture output to avoid pipeline leak)
$result = $quota | Set-NcQuota -DiskLimit "<size>gb" -SoftDiskLimit "<size>gb" -ErrorAction Stop

# 4. Activate the change
Start-NcQuotaResize -VserverContext <svm-name> -Volume <volume>
```

### Auto-Recovery on Resize Failure
```powershell
try {
    Start-NcQuotaResize -VserverContext $svm -Volume $vol -ErrorAction Stop
} catch {
    Write-Warning "Quota resize failed — attempting disable/enable recovery..."
    Disable-NcQuota -VserverContext $svm -Volume $vol -ErrorAction Stop
    Enable-NcQuota -VserverContext $svm -Volume $vol -ErrorAction Stop
    Write-Host "Quotas re-enabled on $vol"
}
```

## Helper: DisplayInKB
```powershell
function DisplayInKB($num) {
    $suffix = "B", "KB", "MB", "GB", "TB", "PB", "EB", "ZB", "YB"
    $index = 0
    while ($num -gt 1kb) {
        $num = $num / 1kb
        $index++
    }
    "{0:N2} {1}" -f $num, $suffix[$index]
}
```

## Interactive Script
The full interactive quota manager script is at:
`Clusters Quota Policy Manger.ps1` (workspace root level, under `scripts/quota/`)

It provides:
- Percentage-based filtering (user picks threshold)
- Out-GridView qtree selection (or filter by name)
- Interactive DiskLimit / SoftDiskLimit input (gb/tb)
- Auto-recovery on `Start-NcQuotaResize` failure
- Post-change report refresh
