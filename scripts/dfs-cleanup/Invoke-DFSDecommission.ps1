<#
.SYNOPSIS
    Resolve, age-assess and decommission DFS-backed CIFS shares, qtrees and volumes on ONTAP.

.DESCRIPTION
    Consolidates the DFS cleanup workflow that previously lived as four loose variants of
    ONTAP\shares\delete-shareNsym*.ps1 plus three helper modules.

    Config-driven, in the same shape as scripts/share-migration:
      - config.json              cluster inventory, DFS_Config, Personal_modules
      - Config_DFSCleanup.json   CyberArk, age thresholds, protected volumes, Excel settings

    Modes:
      Preflight  Report File System Analytics state and access-time tracking per volume.
                 Optionally enable FSA (-EnableAnalytics). Read-only unless that switch is used.
      Resolve    Map each DFS UNC path to its share / volume / qtree / symlink / widelink and
                 record whether the objects still exist. Read-only.
      Analyze    Resolve, then pull FSA evidence and produce a verdict per target. Read-only.
      Report     Analyze, then write a CSV and (optionally) an updated copy of the Excel
                 tracker. Never modifies the source workbook unless WriteMode is InPlace.
      Delete     Remove share, widelink, symlink file and backing qtree/volume — in phases,
                 and ONLY for targets carrying an approved verdict from a prior Analyze/Report.

.PARAMETER Mode
    Which stage to run. Defaults to Resolve, the safest useful action.

.PARAMETER Path
    One or more DFS UNC paths (e.g. \\ns\dfs\ProjectX). Mutually usable with -InputCsv/-FromExcel.

.PARAMETER InputCsv
    CSV with a column holding DFS UNC paths (default column name from config PathColumn).

.PARAMETER FromExcel
    Read the path list from the Excel tracker named in Config_DFSCleanup.json.

.PARAMETER VerdictFile
    CSV produced by -Mode Report. Required by -Mode Delete: a target with no stored verdict
    is refused. This is deliberate — it forces evidence to exist before anything is destroyed.

.PARAMETER ApprovedVerdicts
    Which verdicts -Mode Delete will act on. Defaults to IMMEDIATE and EMPTY only;
    CANDIDATE must be promoted by a human decision, not by a default.

.PARAMETER DeleteBackingStorage
    Also run Phase 2 (qtree/volume removal). Without it, Delete only removes the share,
    widelink and symlink file, leaving the data recoverable.

.PARAMETER PerFileProof
    Collect real per-file timestamps. Required to confirm an IMMEDIATE verdict when
    RequirePerFileProofForImmediate is true in config.

.PARAMETER EnableAnalytics
    Preflight only: turn FSA on where it is off. Starts a full initialization scan.

.PARAMETER Force
    Skip interactive confirmations. Does NOT bypass the verdict requirement or the
    protected-volume guard.

.EXAMPLE
    # Is the analytics data even trustworthy yet?
    .\Invoke-DFSDecommission.ps1 -Mode Preflight

.EXAMPLE
    # Resolve every path in the Excel tracker, write a CSV, touch nothing
    .\Invoke-DFSDecommission.ps1 -Mode Resolve -FromExcel

.EXAMPLE
    # Full assessment with real timestamps, updated workbook copy
    .\Invoke-DFSDecommission.ps1 -Mode Report -FromExcel -PerFileProof

.EXAMPLE
    # Dry run of the deletion for one target
    .\Invoke-DFSDecommission.ps1 -Mode Delete -Path '\\ns\dfs\Alpha' `
        -VerdictFile .\exports\dfs-cleanup-report-20260729.csv -WhatIf

.NOTES
    Maintainer: Project team
    Safety : Destructive work is gated by ShouldProcess, a stored verdict, a protected-volume
             list, and (unless -Force) typing the target name. Phase 1 and Phase 2 are separate.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [ValidateSet('Preflight', 'Resolve', 'Analyze', 'Report', 'Delete')]
    [string]$Mode = 'Resolve',

    [string[]]$Path,
    [string]$InputCsv,
    [switch]$FromExcel,

    [string]$ConfigPath,
    [string]$DFSCleanupConfigPath,

    [string]$VerdictFile,
    [string[]]$ApprovedVerdicts = @('IMMEDIATE', 'EMPTY'),

    [switch]$DeleteBackingStorage,
    [switch]$PerFileProof,
    [switch]$EnableAnalytics,
    [string[]]$Volume,
    [switch]$SkipCertificateCheck,
    [switch]$Force,

    # Where the REST credential comes from. Auto = CyberArk CCP, falling back to the ONTAP
    # toolkit's local credential cache when the CCP is down (read-only modes only).
    [ValidateSet('Auto', 'CyberArk', 'Cache')]
    [string]$CredentialSource = 'Auto',

    # Accept the audit-identity change that the cache fallback implies, for Delete mode.
    [switch]$AllowFallbackForWrite,

    # Path to a JSON manifest that authorises unattended deletion without the interactive
    # challenge. Must be dated today, must name the account running the script, and must list
    # every path individually with the value 'OVERRIDE'. See Import-DFSOverrideManifest.
    # This is the ONLY way to delete without a console; -Force alone does not grant it.
    [string]$OverrideManifest,

    # Delete these paths on a HUMAN's authority instead of stored age evidence. For the case the
    # evidence rule cannot cover: a manager, dev team or legal says a path is no longer needed.
    # Skips the verdict/Approved requirement ONLY. Every safety refusal still applies, the
    # interactive challenge is still required, and it asks who authorised it.
    [string[]]$ForceDeletePath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# =======================================================================================
# Paths, logging
# =======================================================================================

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir '..\..')).Path
$RunStamp = Get-Date -Format 'yyyyMMdd-HHmmss'

function Resolve-UnderRoot {
    param([string]$Candidate, [string]$Fallback)
    $p = if ([string]::IsNullOrWhiteSpace($Candidate)) { $Fallback } else { $Candidate }
    if ([System.IO.Path]::IsPathRooted($p)) { return $p }
    return (Join-Path $RepoRoot $p)
}

$script:LogFile = $null

function Write-DFSLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK', 'STEP')][string]$Level = 'INFO'
    )
    $line = "[{0}] [{1,-5}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $colour = switch ($Level) {
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'STEP'  { 'Cyan' }
        default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $colour
    if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding utf8 }
}

# =======================================================================================
# Config
# =======================================================================================

function Get-DFSCleanupConfig {
    param([string]$MainConfigPath, [string]$CleanupConfigPath)

    $mainPath = if ($MainConfigPath) { $MainConfigPath } else { Join-Path $RepoRoot 'config.json' }
    if (-not (Test-Path -LiteralPath $mainPath)) {
        throw "config.json not found at '$mainPath'. Copy config.template.json and fill it in."
    }
    $main = Get-Content -LiteralPath $mainPath -Raw | ConvertFrom-Json

    $cleanPath = if ($CleanupConfigPath) { $CleanupConfigPath } else { Join-Path $RepoRoot 'Config_DFSCleanup.json' }
    if (-not (Test-Path -LiteralPath $cleanPath)) {
        $tpl = Join-Path $RepoRoot 'Config_DFSCleanup.template.json'
        throw "Config_DFSCleanup.json not found at '$cleanPath'. Copy '$tpl' to that name and fill in the real values."
    }
    $cleanRoot = Get-Content -LiteralPath $cleanPath -Raw | ConvertFrom-Json
    $clean = $cleanRoot.DFSCleanup
    if (-not $clean) { throw "'$cleanPath' has no 'DFSCleanup' section." }

    # Default the optional Excel keys onto the object itself, so every existing
    # $Cfg.Clean.Excel.* call site keeps working and an older config still runs.
    if ($clean.PSObject.Properties.Name -contains 'Excel' -and $clean.Excel) {
        $excelDefaults = @{
            SharePath      = $null   # published copy the manager reads; $null disables both directions
            SyncFromShare  = $true   # pull the manager's added rows before reading
            PublishToShare = $true   # copy the finished workbook back afterwards
        }
        foreach ($k in $excelDefaults.Keys) {
            if ($clean.Excel.PSObject.Properties.Name -notcontains $k) {
                $clean.Excel | Add-Member -NotePropertyName $k -NotePropertyValue $excelDefaults[$k]
            }
        }
    }

    $alias = $clean.ClusterAlias
    $dfs = $null
    if ($main.DFS_Config -and $main.DFS_Config.PSObject.Properties.Name -contains $alias) {
        $dfs = $main.DFS_Config.$alias
    }
    if (-not $dfs) {
        throw "config.json DFS_Config has no entry for cluster alias '$alias'. Add one (Vserver, CifsServer, CifsAlias, DfsShare, DfsPath, Domain)."
    }

    [PSCustomObject]@{
        MainConfigPath = $mainPath
        CleanConfigPath = $cleanPath
        Main           = $main
        Clean          = $clean
        Dfs            = $dfs
        ClusterAlias   = $alias
        RestHost       = $clean.RestHost
        Vserver        = $dfs.Vserver
        CandidateYears = [int]$clean.AgeThresholds.CandidateYears
        ImmediateYears = [int]$clean.AgeThresholds.ImmediateYears
        RequireProof   = [bool]$clean.RequirePerFileProofForImmediate
        Protected      = @($clean.ProtectedVolumes)
        # Optional keys — defaulted here so an older Config_DFSCleanup.json still runs.
        SymlinkScanDepth     = $(if ($clean.PSObject.Properties.Name -contains 'SymlinkScanDepth') { [int]$clean.SymlinkScanDepth } else { 1 })
        SymlinkScanMaxUsedGB = $(if ($clean.PSObject.Properties.Name -contains 'SymlinkScanMaxUsedGB') { [double]$clean.SymlinkScanMaxUsedGB } else { 0 })
        ExportRoot     = Resolve-UnderRoot $clean.ExportRoot 'scripts/dfs-cleanup/exports'
        LogRoot        = Resolve-UnderRoot $clean.LogRoot    'scripts/dfs-cleanup/logs'
    }
}

function Import-DFSModules {
    param([PSCustomObject]$Cfg)

    Import-Module (Join-Path $ScriptDir 'Get-NaApiCred.psm1') -Force -ErrorAction Stop
    Import-Module (Join-Path $ScriptDir 'Get-DFSCleanupAnalytics.psm1') -Force -ErrorAction Stop

    # The DFS path resolver now lives IN the workspace, so a run depends on nothing outside it.
    # config.json Personal_modules is only a fallback, for a machine that still has the original
    # and no local copy.
    $resolver = Join-Path $ScriptDir 'Get-DFSNameSpaceRoot.psm1'
    if (-not (Test-Path -LiteralPath $resolver)) {
        $resolver = @($Cfg.Main.Personal_modules) |
            Where-Object { $_ -match 'Get-DFSNameSpaceRoot\.psm1$' -and (Test-Path -LiteralPath $_) } |
            Select-Object -First 1
        if (-not $resolver) {
            throw ("Get-DFSNameSpaceRoot.psm1 not found in '$ScriptDir' and no usable path in " +
                   'config.json Personal_modules.')
        }
        Write-DFSLog "Local resolver missing — falling back to '$resolver'." 'WARN'
    }
    Import-Module $resolver -Force -ErrorAction Stop

    if (-not (Get-Module -ListAvailable NetApp.ONTAP)) {
        throw 'NetApp.ONTAP module is not installed.'
    }
    Import-Module NetApp.ONTAP -SkipEditionCheck -ErrorAction Stop
    Write-DFSLog "Modules loaded (resolver: $resolver)." 'OK'
}

# =======================================================================================
# Input list
# =======================================================================================

function Import-ExcelSafely {
    <#
    .SYNOPSIS
        Read a worksheet from a workbook that may be open in Excel.
    .DESCRIPTION
        A workbook held open by Excel can be readable one moment and report zero worksheets the
        next, depending on Excel's save/lock state (and OneDrive sync on top of that). Reading a
        temp copy sidesteps it entirely and never touches the original.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$WorksheetName,
        # Column that must exist. Used to LOCATE the header row rather than assuming row 1.
        [string]$RequiredColumn,
        # Explicit override; 0 = detect.
        [int]$HeaderRow = 0
    )

    if (-not (Get-Module -ListAvailable ImportExcel)) {
        throw 'ImportExcel module is required to read the workbook. Install-Module ImportExcel -Scope CurrentUser'
    }
    Import-Module ImportExcel -ErrorAction Stop

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('dfscleanup-' + [guid]::NewGuid().ToString('N') + '.xlsx')
    try {
        try {
            Copy-Item -LiteralPath $Path -Destination $tmp -Force -ErrorAction Stop
        }
        catch {
            throw "Could not copy '$Path' for reading (is it locked by another process?): $($_.Exception.Message)"
        }

        $sheets = @()
        try { $sheets = @(Get-ExcelSheetInfo -Path $tmp | Select-Object -ExpandProperty Name) } catch { }

        if ($sheets.Count -gt 0 -and $WorksheetName -notin $sheets) {
            throw "Worksheet '$WorksheetName' not found in '$Path'. Available: $($sheets -join ', '). Fix Excel.WorksheetName in Config_DFSCleanup.json."
        }

        # Do NOT assume the header is row 1. The plain tracker has headers on row 1, but the
        # styled/published workbook carries a title block above them (headers on row 4). Reading
        # row 1 as the header there yields rows whose PathColumn is empty on every one — the run
        # then aborts with "No DFS paths to work on" while reporting it read 39 rows, which points
        # at the wrong thing entirely. So find the header by looking for the column name.
        $start = $HeaderRow
        if ($start -le 0 -and $RequiredColumn) {
            $raw = @(Import-Excel -Path $tmp -WorksheetName $WorksheetName -NoHeader -ErrorAction Stop)
            for ($i = 0; $i -lt [Math]::Min($raw.Count, 25); $i++) {
                $cells = @($raw[$i].PSObject.Properties | ForEach-Object { [string]$_.Value })
                if ($cells -contains $RequiredColumn) { $start = $i + 1; break }
            }
            if ($start -le 0) {
                throw ("Column '$RequiredColumn' was not found in the first 25 rows of worksheet " +
                       "'$WorksheetName' in '$Path'. Check Excel.PathColumn, or set Excel.HeaderRow.")
            }
            if ($start -gt 1) { Write-DFSLog "  Header row detected at row $start (title block above it)." }
        }
        if ($start -le 0) { $start = 1 }

        return @(Import-Excel -Path $tmp -WorksheetName $WorksheetName -StartRow $start)
    }
    finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Update-DFSWorkbookInPlace {
    <#
    .SYNOPSIS
        Write this run's findings back into the tracker worksheet itself, cell by cell.
    .DESCRIPTION
        The tracker IS the deliverable. Four people read it and add a UNC path in column A when
        they want something investigated; the next run has to fill that row in. Exporting a
        dated results sheet instead left column A rows blank forever and grew a new worksheet
        every day, so that is gone.

        Written with Open-ExcelPackage rather than Export-Excel because Export-Excel replaces a
        worksheet wholesale: the title block, the column widths, the conditional fills, and the
        'Actual Path' formula on every row would all be destroyed. Here only the cells this tool
        owns are assigned, and everything else in the file is left exactly as it was.

        Column ownership is enforced, not assumed:
          - HUMAN columns are never written. Hand-written judgement outranks anything computed.
          - The key column is never written; it is what rows are matched on.
          - Formula cells are never written, whatever column they sit in.
          - A tool column whose value is $null this run is LEFT ALONE, not blanked. A failed
            cluster read must not erase yesterday's good answer.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$WorksheetName,
        [Parameter(Mandatory)][string]$KeyColumn,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Results,
        [int]$HeaderRow = 0
    )

    if (-not (Get-Module -ListAvailable ImportExcel)) {
        throw 'ImportExcel module is required to write the workbook. Install-Module ImportExcel -Scope CurrentUser'
    }
    Import-Module ImportExcel -ErrorAction Stop

    # CAB1 header -> property on the result row. Anything not listed here is never written.
    $map = [ordered]@{
        'Share'              = 'Share'
        'On Volume'          = 'Volume'
        'Size (GB)'          = 'SizeMeasured'
        'UnixPath'           = 'UnixPath'
        'LINK'               = { param($r) if ($r.SymlinkFilePath) { ([string]$r.SymlinkFilePath).TrimStart('/') } else { $null } }
        'Qtree'              = 'Qtree'
        'Status'             = 'Status'
        'DFS Enabled'        = 'DfsEnabled'
        'SymlinkFilePath'    = 'SymlinkFilePath'
        'SymlinkFiles'       = 'SymlinkFileCount'
        'Widelinks'          = 'WidelinkCount'
        'TargetType'         = 'TargetType'
        'DeleteMethod'       = 'DeleteMethod'
        'DeleteRelPath'      = 'DeleteRelPath'
        'OrphanState'        = 'OrphanState'
        'ResolvedVia'        = 'ResolvedVia'
        'QuotaLimit'         = 'QuotaLimit'
        'QuotaUsed'          = 'QuotaUsed'
        'FSA State'          = 'FsaStateText'
        'Last Accessed'      = 'LastAccessedText'
        'Last Modified'      = 'LastModifiedText'
        'ClusterCheck'       = 'ClusterCheck'
        'AutoNotes'          = 'AutoNotes'
        'Content (measured)' = 'ContentMeasured'
    }

    # Named so the intent survives someone reading this in a year: these hold human judgement,
    # and the tool has no business overwriting them.
    #
    # 'Size (GB)' is deliberately NOT in this list any more. It was hand-maintained and went
    # badly stale — 2.47 GiB recorded against a qtree that measures zero, 1.55 TiB against three
    # paths that do not exist. A figure nobody re-checks is worse than no figure, so it is now
    # measured every run. The hand-entered values survive in the '.bak-<stamp>.xlsx' backups and
    # in 'Volumes or Qtree to Delete - ORIGINAL.xlsx'.
    $humanColumns = @('Comments', 'commands', 'Is Backuped', 'Actual Path')

    $pkg = Open-ExcelPackage -Path $Path
    try {
        $ws = $pkg.Workbook.Worksheets[$WorksheetName]
        if (-not $ws) {
            throw "Worksheet '$WorksheetName' not found in '$Path'. Available: $(($pkg.Workbook.Worksheets | ForEach-Object Name) -join ', ')."
        }

        $lastRow = $ws.Dimension.End.Row
        $lastCol = $ws.Dimension.End.Column

        # Locate the header row by finding the key column, same rule as the reader.
        $hdrRow = $HeaderRow
        if ($hdrRow -le 0) {
            for ($r = 1; $r -le [Math]::Min($lastRow, 25); $r++) {
                for ($c = 1; $c -le $lastCol; $c++) {
                    if ([string]$ws.Cells[$r, $c].Text -eq $KeyColumn) { $hdrRow = $r; break }
                }
                if ($hdrRow -gt 0) { break }
            }
        }
        if ($hdrRow -le 0) { throw "Key column '$KeyColumn' not found in the first 25 rows of '$WorksheetName'." }

        $colOf = @{}
        for ($c = 1; $c -le $lastCol; $c++) {
            $h = [string]$ws.Cells[$hdrRow, $c].Text
            if ($h -and -not $colOf.ContainsKey($h)) { $colOf[$h] = $c }
        }
        if (-not $colOf.ContainsKey($KeyColumn)) { throw "Key column '$KeyColumn' missing from the header row." }
        $keyCol = $colOf[$KeyColumn]

        # A tool column the sheet does not have yet is APPENDED rather than skipped. Silently
        # dropping it means a newly added column never appears and nobody can tell whether the
        # data was missing or the column was. New headers go on the end so existing column
        # positions — and anything referring to them — are undisturbed.
        foreach ($hdr in $map.Keys) {
            if ($colOf.ContainsKey($hdr) -or $hdr -in $humanColumns) { continue }
            $lastCol++
            $ws.Cells[$hdrRow, $lastCol].Value = $hdr
            $ws.Cells[$hdrRow, $lastCol].Style.Font.Bold = $true
            $colOf[$hdr] = $lastCol
            Write-DFSLog "  Added missing column '$hdr' to '$WorksheetName' at position $lastCol." 'OK'
        }

        # Normalising the key matters: the tracker has carried trailing spaces ('...\Inst ') and
        # inconsistent case. Matching on the raw string silently fails to find the row and the
        # findings vanish with no error at all.
        $norm = { param($s) ([string]$s).Trim().TrimEnd('\').ToLowerInvariant() }

        $rowOfPath = @{}
        for ($r = $hdrRow + 1; $r -le $lastRow; $r++) {
            $k = & $norm $ws.Cells[$r, $keyCol].Text
            if ($k -and -not $rowOfPath.ContainsKey($k)) { $rowOfPath[$k] = $r }
        }

        $written = 0; $rowsTouched = 0; $unmatched = [System.Collections.Generic.List[string]]::new()
        $skippedFormula = 0

        foreach ($res in $Results) {
            $k = & $norm $res.DfsPath
            if (-not $k) { continue }
            if (-not $rowOfPath.ContainsKey($k)) { $unmatched.Add([string]$res.DfsPath); continue }
            $r = $rowOfPath[$k]
            $touched = $false

            foreach ($hdr in $map.Keys) {
                if (-not $colOf.ContainsKey($hdr)) { continue }
                if ($hdr -in $humanColumns) { continue }

                $spec = $map[$hdr]
                $value = if ($spec -is [scriptblock]) { & $spec $res }
                         elseif ($res.PSObject.Properties.Name -contains $spec) { $res.$spec }
                         else { $null }

                # Leave the cell alone rather than blanking it — see the .DESCRIPTION note.
                if ($null -eq $value -or ($value -is [string] -and $value -eq '')) { continue }

                $cell = $ws.Cells[$r, $colOf[$hdr]]
                if ($cell.Formula) { $skippedFormula++; continue }

                $cell.Value = if ($value -is [bool]) { $value } else { [string]$value }
                $written++
                $touched = $true
            }
            if ($touched) { $rowsTouched++ }
        }

        if ($unmatched.Count -gt 0) {
            Write-DFSLog "$($unmatched.Count) analysed path(s) had no row in '$WorksheetName' and were not written: $($unmatched -join '; ')" 'WARN'
        }
        if ($skippedFormula -gt 0) {
            Write-DFSLog "  Left $skippedFormula formula cell(s) untouched."
        }

        if ($PSCmdlet.ShouldProcess($Path, "Update $rowsTouched row(s) / $written cell(s) in worksheet '$WorksheetName'")) {
            # Close-ExcelPackage SAVES by default; there is no -Save parameter (only -NoSave and
            # -SaveAs <path>). Passing -Save fails with "Missing an argument for parameter 'SaveAs'".
            Close-ExcelPackage $pkg
            $pkg = $null
            Write-DFSLog "Updated '$WorksheetName' in place: $rowsTouched row(s), $written cell(s)." 'OK'
        }
        else {
            Close-ExcelPackage $pkg -NoSave
            $pkg = $null
            Write-DFSLog "WhatIf: would update $rowsTouched row(s) / $written cell(s) in '$WorksheetName'." 'WARN'
        }

        return [PSCustomObject]@{
            HeaderRow    = $hdrRow
            RowsTouched  = $rowsTouched
            CellsWritten = $written
            Unmatched    = @($unmatched)
        }
    }
    finally {
        if ($pkg) { Close-ExcelPackage $pkg -NoSave }
    }
}

function Set-DFSWorkbookSheet {
    <#
    .SYNOPSIS
        Replace a whole worksheet's contents from a set of objects.
    .DESCRIPTION
        For the pure-OUTPUT sheets — Symlink_Map and Anomalies. Nobody hand-edits those, so
        rebuilding them wholesale each run is both simpler and safer than cell-matching, and it
        is the only way a REMOVED symlink ever disappears from the map. That is the opposite of
        CAB1, which people type into and which is therefore filled cell by cell with the human
        columns protected (see Update-DFSWorkbookInPlace).

        -ClearSheet is what makes this a replace rather than an append: without it, a run with
        fewer rows than the last would leave the previous run's surplus rows behind, silently
        reporting symlinks that no longer exist.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$WorksheetName,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows
    )

    if (-not $Rows -or $Rows.Count -eq 0) {
        # Deliberately NOT clearing the sheet here. An empty result is far more likely to mean
        # "the scan failed" than "every symlink was deleted", and wiping a good map on a bad run
        # would destroy the only record of where 200-odd symlink files live.
        Write-DFSLog "  '$WorksheetName': no rows produced — sheet left untouched rather than emptied." 'WARN'
        return $false
    }

    if (-not $PSCmdlet.ShouldProcess($Path, "Rebuild worksheet '$WorksheetName' with $($Rows.Count) row(s)")) {
        Write-DFSLog "  WhatIf: would rebuild '$WorksheetName' with $($Rows.Count) row(s)." 'WARN'
        return $false
    }

    # Export-Excel -ClearSheet drops and recreates the worksheet, which lands it at the END of
    # the tab order. Left alone, every run shuffles the workbook's tabs — and people navigate
    # this file by tab. So the original position is captured and restored.
    $origOrder = @()
    try {
        $probe = Open-ExcelPackage -Path $Path
        $origOrder = @($probe.Workbook.Worksheets | ForEach-Object Name)
        Close-ExcelPackage $probe -NoSave
    }
    catch { }
    $wasAt = [Array]::IndexOf($origOrder, $WorksheetName)

    $Rows | Export-Excel -Path $Path -WorksheetName $WorksheetName -ClearSheet `
                -AutoSize -FreezeTopRow -BoldTopRow

    if ($wasAt -ge 0) {
        try {
            $pkg = Open-ExcelPackage -Path $Path
            $now = @($pkg.Workbook.Worksheets | ForEach-Object Name)
            if ([Array]::IndexOf($now, $WorksheetName) -ne $wasAt) {
                if ($wasAt -eq 0) { $pkg.Workbook.Worksheets.MoveToStart($WorksheetName) }
                else { $pkg.Workbook.Worksheets.MoveAfter($WorksheetName, $origOrder[$wasAt - 1]) }
                Close-ExcelPackage $pkg
            }
            else { Close-ExcelPackage $pkg -NoSave }
        }
        catch { Write-DFSLog "  '$WorksheetName' rebuilt but could not be moved back to position $($wasAt + 1): $($_.Exception.Message)" 'WARN' }
    }

    Write-DFSLog "  Rebuilt '$WorksheetName': $($Rows.Count) row(s)." 'OK'
    return $true
}

function Get-DFSFileHash {
    # $null when the file is missing or unreadable, so callers can treat "cannot compare" as
    # "assume different" rather than "assume same".
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash }
    catch { return $null }
}

function Sync-DFSWorkbookFromShare {
    <#
    .SYNOPSIS
        Pull the shared workbook down to the local master before reading it.
    .DESCRIPTION
        The workbook on the share is the copy the manager sees and edits — new shares to
        investigate get added there, not locally. Reading a stale local master would silently
        skip those rows, so the share is checked first.

        Direction is decided by timestamp, never blindly: the share only overwrites the local
        master when it is genuinely NEWER. If the local copy is ahead (our own results not yet
        published) it is left alone and the difference is reported. Either way the local file is
        backed up before being replaced, because "pull" must never be able to lose work.

        A symlink was the original plan here. It is not usable: the workspace sits inside a
        OneDrive-synced tree, where a reparse point is turned into a cloud placeholder
        (tag 0x9000601a), and creating one pointing at a UNC path is blocked outright by
        endpoint security. Copying is the reliable mechanism.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LocalPath,
        [Parameter(Mandatory)][string]$SharePath
    )

    if (-not (Test-Path -LiteralPath $SharePath)) {
        Write-DFSLog "Shared workbook '$SharePath' is not reachable — using the local master as-is." 'WARN'
        return 'ShareUnavailable'
    }

    if (-not (Test-Path -LiteralPath $LocalPath)) {
        $dir = Split-Path -Parent $LocalPath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Copy-Item -LiteralPath $SharePath -Destination $LocalPath -Force
        Write-DFSLog "No local master — copied the shared workbook to '$LocalPath'." 'OK'
        return 'Pulled'
    }

    if ((Get-DFSFileHash $LocalPath) -eq (Get-DFSFileHash $SharePath) -and (Get-DFSFileHash $LocalPath)) {
        Write-DFSLog 'Local master matches the shared workbook.' 'OK'
        return 'Identical'
    }

    $shareTime = (Get-Item -LiteralPath $SharePath).LastWriteTime
    $localTime = (Get-Item -LiteralPath $LocalPath).LastWriteTime

    if ($shareTime -gt $localTime) {
        $backup = [System.IO.Path]::ChangeExtension($LocalPath, $null).TrimEnd('.') +
                  ".local-$RunStamp.xlsx"
        Copy-Item -LiteralPath $LocalPath -Destination $backup -Force
        Copy-Item -LiteralPath $SharePath -Destination $LocalPath -Force
        Write-DFSLog ("Shared workbook is newer ($($shareTime.ToString('yyyy-MM-dd HH:mm')) vs " +
                      "$($localTime.ToString('yyyy-MM-dd HH:mm'))) — pulled it down. Rows added on the " +
                      'share are now included. Previous local copy kept as ' +
                      "'$(Split-Path $backup -Leaf)'.") 'OK'
        return 'Pulled'
    }

    Write-DFSLog ("Local master differs from the share but is NEWER " +
                  "($($localTime.ToString('yyyy-MM-dd HH:mm')) vs $($shareTime.ToString('yyyy-MM-dd HH:mm'))) — " +
                  'keeping local. If the manager added rows on the share, publish or reconcile first.') 'WARN'
    return 'LocalAhead'
}

function Publish-DFSWorkbookToShare {
    <#
    .SYNOPSIS
        Copy the finished workbook to the share so the manager sees it.
    .DESCRIPTION
        The share copy is backed up before being overwritten — it is the version other people
        have been looking at, and it may contain edits this run never saw.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$LocalPath,
        [Parameter(Mandatory)][string]$SharePath
    )

    if (-not (Test-Path -LiteralPath $LocalPath)) {
        Write-DFSLog "Nothing to publish — '$LocalPath' does not exist." 'WARN'
        return
    }

    $shareDir = Split-Path -Parent $SharePath
    if (-not (Test-Path -LiteralPath $shareDir)) {
        Write-DFSLog ("Cannot publish: '$shareDir' is not reachable. The workbook is complete at " +
                      "'$LocalPath' — copy it across by hand once the share is available.") 'WARN'
        return
    }

    if (-not $PSCmdlet.ShouldProcess($SharePath, 'Publish the updated workbook')) { return }

    if (Test-Path -LiteralPath $SharePath) {
        $backup = [System.IO.Path]::ChangeExtension($SharePath, $null).TrimEnd('.') + ".bak-$RunStamp.xlsx"
        try {
            Copy-Item -LiteralPath $SharePath -Destination $backup -Force -ErrorAction Stop
            Write-DFSLog "Backed up the existing shared workbook to '$(Split-Path $backup -Leaf)'."
        }
        catch {
            Write-DFSLog "Could not back up the shared workbook: $($_.Exception.Message)" 'WARN'
        }
    }

    try {
        Copy-Item -LiteralPath $LocalPath -Destination $SharePath -Force -ErrorAction Stop
        Write-DFSLog "Published to '$SharePath'." 'OK'
    }
    catch {
        # Almost always the manager has it open in Excel.
        Write-DFSLog ("Publish FAILED: $($_.Exception.Message). The file is probably open by " +
                      "someone. The result is safe at '$LocalPath' — retry once it is closed.") 'ERROR'
    }
}

function Get-TargetPaths {
    param([PSCustomObject]$Cfg, [string[]]$Explicit, [string]$Csv, [switch]$Excel)

    $list = [System.Collections.Generic.List[string]]::new()

    foreach ($p in @($Explicit)) {
        if (-not [string]::IsNullOrWhiteSpace($p)) { $list.Add($p.Trim()) }
    }

    $column = $Cfg.Clean.Excel.PathColumn

    if ($Csv) {
        if (-not (Test-Path -LiteralPath $Csv)) { throw "InputCsv '$Csv' not found." }
        $rows = @(Import-Csv -LiteralPath $Csv)
        if (-not $rows) { throw "InputCsv '$Csv' contains no rows." }
        $col = if ($rows[0].PSObject.Properties.Name -contains $column) { $column } else { @($rows[0].PSObject.Properties.Name)[0] }
        foreach ($r in $rows) {
            $v = $r.$col
            if (-not [string]::IsNullOrWhiteSpace($v)) { $list.Add(([string]$v).Trim()) }
        }
        Write-DFSLog "Read $($rows.Count) rows from CSV '$Csv' (column '$col')."
    }

    if ($Excel) {
        $xlsx = $Cfg.Clean.Excel.SourcePath

        # The manager adds new shares to investigate on the SHARE copy. Pull it down first, or
        # those rows are silently missing from this run.
        if ($Cfg.Clean.Excel.SharePath -and $Cfg.Clean.Excel.SyncFromShare) {
            $null = Sync-DFSWorkbookFromShare -LocalPath $xlsx -SharePath $Cfg.Clean.Excel.SharePath
        }

        if (-not (Test-Path -LiteralPath $xlsx)) { throw "Excel SourcePath '$xlsx' not found." }
        $headerRow = 0
        if ($Cfg.Clean.Excel.PSObject.Properties.Name -contains 'HeaderRow') { $headerRow = [int]$Cfg.Clean.Excel.HeaderRow }
        $rows = @(Import-ExcelSafely -Path $xlsx -WorksheetName $Cfg.Clean.Excel.WorksheetName `
                    -RequiredColumn $column -HeaderRow $headerRow)
        if (-not $rows) { throw "Worksheet '$($Cfg.Clean.Excel.WorksheetName)' in '$xlsx' contains no rows." }
        foreach ($r in $rows) {
            $v = if ($r.PSObject.Properties.Name -contains $column) { $r.$column } else { $null }
            if (-not [string]::IsNullOrWhiteSpace($v)) { $list.Add(([string]$v).Trim()) }
        }
        Write-DFSLog "Read $($rows.Count) rows from '$xlsx' sheet '$($Cfg.Clean.Excel.WorksheetName)' (column '$column')."
    }

    # Trailing spaces in the tracker ("\\ns\dfs\Inst ") break the resolver's path split.
    $clean = $list | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique
    if (-not $clean) { throw 'No DFS paths to work on. Pass -Path, -InputCsv or -FromExcel.' }
    Write-DFSLog "$(@($clean).Count) unique target path(s)."
    return @($clean)
}

# =======================================================================================
# Resolve
# =======================================================================================

$script:QtreeCache = $null
$script:SymlinkCache = $null
$script:SymlinkFileIndex = $null
# Raw container-volume scan, kept so the Symlink_Map / Anomalies sheets can be built without
# repeating it. That scan is the slowest thing in a run (~80s); doing it twice would double it.
$script:SymlinkContainers = $null

function Get-DFSSymlinkFileIndex {
    <#
    .SYNOPSIS
        Build the container-volume -> symlink-file index that ONTAP does not expose.
    .DESCRIPTION
        The widelink table is keyed on a bare relative name ('/Link1/') and holds no reference to
        the volume whose root contains the symlink FILE. Get-DFSNameSpaceRoot fabricates a LINK
        path from the input UNC instead ('\\<alias>\dfs\Link1' -> '/vol/dfsroot/Link1'), which is wrong
        whenever the file actually lives in another container — Link1's file is in /vol/DFSROOT_B.

        Removing the widelink but rm'ing a fabricated path leaves the real dead symlink file in
        place, so the path has to be discovered. Built once per run.
    #>
    param([PSCustomObject]$Cfg, [PSCustomObject]$Context)

    if ($null -ne $script:SymlinkFileIndex) { return $script:SymlinkFileIndex }

    Write-DFSLog "  Discovering DFS container volumes and symlink files (once per run, depth $($Cfg.SymlinkScanDepth))..."
    $index = [System.Collections.Generic.List[object]]::new()
    try {
        $all = @(Find-NaDFSContainerVolumes -Context $Context -Vserver $Cfg.Vserver `
                    -MaxDepth ([int]$Cfg.SymlinkScanDepth) -MaxUsedGB ([double]$Cfg.SymlinkScanMaxUsedGB))
        $summary = $all | Where-Object { $_.IsSummary } | Select-Object -First 1
        $script:SymlinkContainers = @($all | Where-Object { -not $_.IsSummary })

        # Not every symlink file is a DFS widelink. A plain UNIX symlink points at a real
        # filesystem path (e.g. an installer volume's app.exe -> /SomeVol/.../app.sh)
        # and has no widelink-table entry. Only widelinks matter for DFS cleanup, and confusing
        # the two would mean unlinking an application's symlink.
        $wlKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        try {
            foreach ($w in @(Get-NcCifsSymlink -VserverContext $Cfg.Vserver -ErrorAction Stop)) {
                [void]$wlKeys.Add("$($w.UnixPath)".Trim('/'))
            }
        }
        catch { Write-DFSLog "  Could not read the widelink table to classify symlinks: $($_.Exception.Message)" 'WARN' }

        $plain = 0
        foreach ($c in @($all | Where-Object { -not $_.IsSummary })) {
            foreach ($s in @($c.Symlinks)) {
                $key = "$($s.Target)".Trim('/')
                $isWidelink = $wlKeys.Contains($key)
                if (-not $isWidelink) { $plain++ }
                $index.Add([PSCustomObject]@{
                    Container     = $c.Volume
                    ContainerUuid = $c.Uuid
                    SymlinkFile   = $s.FilePath
                    Target        = $s.Target
                    TargetKey     = $key.ToLowerInvariant()
                    IsWidelink    = $isWidelink
                    IsNested      = [bool]$s.ParentPath
                })
            }
            if ($c.DirBudgetHit) {
                Write-DFSLog "  '$($c.Volume)': directory budget hit — some subdirectories were not scanned." 'WARN'
            }
            if ($c.NestedSymlinks -gt 0) {
                Write-DFSLog "  '$($c.Volume)': $($c.NestedSymlinks) symlink(s) found BELOW the volume root." 'WARN'
            }
        }

        $containers = @($index.Container | Sort-Object -Unique)
        $nested = @($index | Where-Object { $_.IsNested }).Count
        Write-DFSLog "  Indexed $($index.Count) symlink file(s) across $($containers.Count) volume(s): $($containers -join ', ')" 'OK'
        Write-DFSLog "  Of these: $($index.Count - $plain) are DFS widelinks, $plain are plain UNIX symlinks (ignored for DFS cleanup), $nested sit below a volume root."

        # Never let coverage gaps read as "nothing there".
        if ($summary) {
            foreach ($sk in @($summary.SkippedVolumes)) {
                Write-DFSLog "  NOT SCANNED: $($sk.Volume) ($($sk.UsedGB) GB) — $($sk.Reason)." 'WARN'
            }
            if ($summary.FailedVolumes.Count -gt 0) {
                Write-DFSLog "  COULD NOT LIST: $((@($summary.FailedVolumes | ForEach-Object { $_.Volume })) -join ', ') — container status unknown for these." 'WARN'
            }
        }
    }
    catch {
        Write-DFSLog "  Could not build symlink file index: $($_.Exception.Message)" 'WARN'
    }

    $script:SymlinkFileIndex = $index.ToArray()
    return $script:SymlinkFileIndex
}

function Get-DFSWidelinksForShare {
    <#
    .SYNOPSIS
        Find every CIFS widelink that targets a given share.
    .DESCRIPTION
        A share can be the target of more than one widelink. Observed on this SVM:
        'Embedded_Releases$' is reachable as both \\ns\dfs\Embedded_Releases and
        \\ns\dfs\TN\Embedded_Releases, and 'ECTEL_Public$' as both /ECTEL_Public/ and /Embedded/.

        Removing the share to tidy up one dead DFS link therefore breaks the other link, which
        may be perfectly live. Removing just the one widelink is safe; removing the share is not.
        The widelink table is indexed once per run.
    #>
    param([PSCustomObject]$Cfg, [string]$ShareName)

    if ([string]::IsNullOrWhiteSpace($ShareName)) { return @() }

    if ($null -eq $script:SymlinkCache) {
        Write-DFSLog '  Building widelink index (once per run)...'
        try { $script:SymlinkCache = @(Get-NcCifsSymlink -VserverContext $Cfg.Vserver -ErrorAction Stop) }
        catch {
            Write-DFSLog "  Could not build widelink index: $($_.Exception.Message)" 'WARN'
            $script:SymlinkCache = @()
        }
    }

    return @($script:SymlinkCache | Where-Object { $_.ShareName -eq $ShareName })
}

function Get-DFSNameCandidate {
    <#
    .SYNOPSIS
        Derive the object base name from a DFS UNC path.
    .DESCRIPTION
        '\\ns\dfs\Alpha' -> 'Alpha'; '\\cifsAlias\Birthday$' -> 'Birthday';
        '\\ns\dfs\Dept\PT' -> 'PT'. Used only for the orphan fallback, where the widelink that
        would normally answer this is already gone.
    #>
    param([Parameter(Mandatory)][string]$DfsPath)
    $tokens = @($DfsPath.Trim() -split '\\+' | Where-Object { $_ -ne '' })
    if ($tokens.Count -eq 0) { return '' }
    return ($tokens[-1] -replace '\$$', '')
}

function Resolve-DFSTargetByName {
    <#
    .SYNOPSIS
        Fallback resolution for targets whose DFS widelink is already gone.
    .DESCRIPTION
        Get-DFSNameSpaceRoot resolves widelink-first, so once the widelink is removed it reports
        "widelink not found" even when the share, qtree and all the data are still present. A
        Phase-1-only cleanup leaves exactly that state, and a tracker row saying DELETED can
        still have gigabytes sitting behind it.

        Looks for, in order: a CIFS share named <name>$ or <name>, then a qtree named <name>_Q
        or <name> anywhere on the SVM. Reports how it was found so nothing silently looks like a
        normal resolution.
    #>
    param([PSCustomObject]$Cfg, [string]$DfsPath)

    $name = Get-DFSNameCandidate -DfsPath $DfsPath
    $svm = $Cfg.Vserver
    $out = [PSCustomObject]@{
        Found = $false; Via = 'None'; Share = $null; SharePath = $null
        Volume = $null; Qtree = $null; Note = $null
    }
    if ([string]::IsNullOrWhiteSpace($name)) { return $out }

    foreach ($candidate in @("$name`$", $name)) {
        $sh = $null
        try { $sh = Get-NcCifsShare -ShareName $candidate -VserverContext $svm -ErrorAction SilentlyContinue } catch { }
        $sh = @($sh) | Where-Object { $_ } | Select-Object -First 1
        if ($sh) {
            $out.Found = $true
            $out.Via = 'ShareByName'
            $out.Share = $sh.ShareName
            $out.SharePath = $sh.Path
            $parts = @("$($sh.Path)".Trim('/') -split '/' | Where-Object { $_ -ne '' })
            if ($parts.Count -ge 1) { $out.Volume = $parts[0] }
            if ($parts.Count -ge 2) { $out.Qtree = $parts[1] }
            $out.Note = "DFS widelink missing, but CIFS share '$($sh.ShareName)' still exists at '$($sh.Path)'."
            return $out
        }
    }

    if ($null -eq $script:QtreeCache) {
        Write-DFSLog '  Building qtree index for orphan lookup (once per run)...'
        try { $script:QtreeCache = @(Get-NcQtree -VserverContext $svm -ErrorAction Stop) }
        catch {
            Write-DFSLog "  Could not build qtree index: $($_.Exception.Message)" 'WARN'
            $script:QtreeCache = @()
        }
    }

    $q = $script:QtreeCache |
         Where-Object { $_.Qtree -and ($_.Qtree -eq "${name}_Q" -or $_.Qtree -eq $name) } |
         Select-Object -First 1
    if ($q) {
        $out.Found = $true
        $out.Via = 'QtreeByName'
        $out.Volume = $q.Volume
        $out.Qtree = $q.Qtree
        $out.SharePath = "/$($q.Volume)/$($q.Qtree)"
        $out.Note = "ORPHAN: no widelink and no CIFS share, but qtree '$($q.Qtree)' still exists on volume '$($q.Volume)'."
        return $out
    }

    $out.Note = "No widelink, no CIFS share named '$name`$'/'$name', and no qtree named '${name}_Q'/'$name' — appears fully deleted."
    return $out
}

function Resolve-DFSTarget {
    param([PSCustomObject]$Cfg, [string]$DfsPath, [PSCustomObject]$RestContext)

    $row = [ordered]@{
        DfsPath           = $DfsPath
        Resolved          = $false
        Share             = $null
        Volume            = $null
        Qtree             = $null
        UnixPath          = $null
        Link              = $null
        SharePath         = $null
        SharePathInVolume = $null
        SubPathSuffix     = $null
        DeleteRelPath     = $null
        JunctionPath      = $null
        CifsServer        = $null
        Vserver           = $Cfg.Vserver
        Aggregate         = $null
        Node              = $null
        QuotaLimit        = $null
        QuotaUsed         = $null
        TargetType        = $null
        DeleteMethod      = $null
        ResolvedVia       = $null
        OrphanState       = $null
        WidelinkCount     = $null
        SharedWithLinks   = $null
        SymlinkContainer  = $null
        SymlinkFilePath   = $null
        SymlinkFileCount  = $null
        ShareExists       = $null
        QtreeExists       = $null
        VolumeExists      = $null
        Note              = $null
    }

    # Get-DFSNameSpaceRoot caps at \\server\dfsshare\link\one-more-level and errors beyond it,
    # so deeper paths are resolved at the link level and the remainder carried separately.
    $tokens = @($DfsPath.Trim() -split '\\+' | Where-Object { $_ -ne '' })
    $resolveTarget = $DfsPath
    $extraTokens = @()
    if ($tokens.Count -gt 3) {
        # Everything past \\server\dfsshare\link is a candidate sub-path. Whether the resolver
        # actually consumed it is decided AFTER resolution, by inspecting LINK.
        $extraTokens = @($tokens[3..($tokens.Count - 1)])
    }
    if ($tokens.Count -gt 4) {
        $resolveTarget = '\\' + (($tokens[0..2]) -join '\')
    }

    $info = $null
    $widelinkError = $null
    try {
        $info = Get-DFSNameSpaceRoot -share $resolveTarget -Vserver $Cfg.Vserver
    }
    catch {
        $widelinkError = $_.Exception.Message
    }

    if (-not $info) {
        # Widelink path failed. Before writing this off as deleted, look for the objects by
        # name — a Phase-1-only cleanup removes the widelink and leaves the data behind.
        $fb = Resolve-DFSTargetByName -Cfg $Cfg -DfsPath $DfsPath
        $row.ResolvedVia = $fb.Via
        $row.Note = (@("Widelink resolution failed: $widelinkError", $fb.Note) | Where-Object { $_ }) -join ' '

        if (-not $fb.Found) {
            $row.OrphanState = 'FullyGone'
            $row.ShareExists = $false
            $row.QtreeExists = $false
            return [PSCustomObject]$row
        }

        $row.Resolved   = $true
        $row.Share      = $fb.Share
        $row.Volume     = $fb.Volume
        $row.Qtree      = $fb.Qtree
        $row.SharePath  = $fb.SharePath
        $row.OrphanState = if ($fb.Via -eq 'ShareByName') { 'OrphanShare' } else { 'OrphanQtree' }
    }
    else {
        $row.ResolvedVia = 'Widelink'
        $row.OrphanState = 'Live'
    }

    # Only overwrite from the resolver when it actually returned something — otherwise the
    # orphan fallback's findings above would be wiped back to null.
    if ($info) {
        $get = {
            param($obj, $name)
            if ($obj.PSObject.Properties.Name -contains $name) { $obj.$name } else { $null }
        }

        $row.Resolved     = $true
        $row.Share        = & $get $info 'Share'
        $row.Volume       = & $get $info 'Volume'
        $row.Qtree        = & $get $info 'QTREE'
        $row.UnixPath     = & $get $info 'UnixPath'
        $row.Link         = & $get $info 'LINK'
        $row.SharePath    = & $get $info 'SharePath'
        $row.JunctionPath = & $get $info 'JunctionPath'
        $row.CifsServer   = & $get $info 'CifsServer'
        $row.Aggregate    = & $get $info 'Aggregate'
        $row.Node         = (& $get $info 'Node') -join ','
        $row.QuotaLimit   = & $get $info 'QuotaLimit'
        $row.QuotaUsed    = & $get $info 'QuotaUsed'
        if (& $get $info 'vserver') { $row.Vserver = & $get $info 'vserver' }
    }

    # Existence probes. The tracker's Status column is not authoritative — at least one row
    # marked DELETED turned out to be merely empty — so what the cluster reports wins.
    try {
        $row.ShareExists = [bool](Get-NcCifsShare -ShareName $row.Share -VserverContext $row.Vserver -ErrorAction SilentlyContinue)
    } catch { $row.ShareExists = $false }

    if ($row.Volume) {
        try {
            $vol = Get-NcVol -Name $row.Volume -VserverContext $row.Vserver -ErrorAction SilentlyContinue
            $row.VolumeExists = [bool]$vol
        } catch { $row.VolumeExists = $false }
    }

    if ($row.Volume -and $row.Qtree) {
        try {
            $q = Get-NcQtree -Volume $row.Volume -VserverContext $row.Vserver -ErrorAction SilentlyContinue |
                 Where-Object { $_.Qtree -eq $row.Qtree }
            $row.QtreeExists = [bool]$q
        } catch { $row.QtreeExists = $false }
    }

    # ---- Where does the symlink FILE actually live? ---------------------------------------
    # Discovered, never inferred from the UNC path. Matched on the widelink's UnixPath, which is
    # what the symlink file's target contains.
    if ($RestContext -and -not [string]::IsNullOrWhiteSpace($row.UnixPath)) {
        $key = "$($row.UnixPath)".Trim('/').ToLowerInvariant()
        # Only widelink symlinks are candidates — a plain UNIX symlink that happens to share a
        # target string is an application link and must never be unlinked by DFS cleanup.
        $hits = @(Get-DFSSymlinkFileIndex -Cfg $Cfg -Context $RestContext |
                  Where-Object { $_.TargetKey -eq $key -and $_.IsWidelink })
        $row.SymlinkFileCount = $hits.Count
        if ($hits.Count -ge 1) {
            $row.SymlinkContainer = (@($hits | ForEach-Object { $_.Container }) -join ' ; ')
            $row.SymlinkFilePath  = (@($hits | ForEach-Object { "/$($_.Container)/$($_.SymlinkFile)" }) -join ' ; ')
        }
        if ($hits.Count -gt 1) {
            # Same target, different containers: several namespace routes to ONE link. Retiring
            # the link requires removing every one of these files. Distinct from several
            # widelink entries sharing a share, which is what blocks share removal.
            $row.Note = (@($row.Note,
                "$($hits.Count) symlink files route to this single widelink ($($row.SymlinkFilePath)) — all must be removed to retire the link.") |
                Where-Object { $_ }) -join ' '
        }
        elseif ($hits.Count -eq 0 -and $row.Link) {
            $row.Note = (@($row.Note,
                "No symlink file found for widelink '$($row.UnixPath)' in any container volume — the widelink entry is unreachable from the namespace.") |
                Where-Object { $_ }) -join ' '
        }
    }

    # ---- Is this share shared by more than one DFS link? ---------------------------------
    if ($row.Share) {
        # @() at the call site: PowerShell unwraps a single-element array on return, and under
        # StrictMode reading .Count off the resulting scalar throws.
        $links = @(Get-DFSWidelinksForShare -Cfg $Cfg -ShareName $row.Share)
        $row.WidelinkCount = $links.Count
        if ($links.Count -gt 1) {
            $row.SharedWithLinks = (@($links | ForEach-Object { $_.UnixPath }) -join ' ; ')
            $row.Note = (@($row.Note,
                "SHARED SHARE: $($links.Count) widelinks target '$($row.Share)' ($($row.SharedWithLinks)). Removing the share would break the other link(s).") |
                Where-Object { $_ }) -join ' '
        }
    }

    # ---- Classify: which delete primitive is correct for this target? --------------------
    # Both decisions are pure functions in Get-DFSCleanupAnalytics.psm1 so they can be unit
    # tested — picking the wrong primitive here destroys data that was not targeted.
    $subSuffix = Get-DFSSubPathSuffix -DfsPath $DfsPath -Link $row.Link
    $row.SubPathSuffix = $subSuffix

    if ($subSuffix) {
        $row.Note = (@($row.Note,
            "Trailing path '$subSuffix' was not consumed by the resolver — treated as a folder inside the share, NOT as the qtree.") |
            Where-Object { $_ }) -join ' '
    }

    $isWidelink = -not [string]::IsNullOrWhiteSpace($row.Link) -and $row.Link -ne 'none'
    $class = Get-DFSDeleteClassification -SharePath $row.SharePath -UnixPath $row.UnixPath `
                -SubPathSuffix $subSuffix -QtreeExists $row.QtreeExists -IsWidelink $isWidelink

    $row.SharePathInVolume = $class.SharePathInVolume
    $row.DeleteRelPath     = $class.DeleteRelPath
    $row.TargetType        = $class.TargetType
    $row.DeleteMethod      = $class.DeleteMethod

    if ($class.DeleteMethod -eq 'Directory' -and -not $subSuffix -and $row.QtreeExists -ne $true) {
        $row.Note = (@($row.Note, "Share path component is a directory, not a qtree — delete as a directory, never as a qtree.") |
                     Where-Object { $_ }) -join ' '
    }

    return [PSCustomObject]$row
}

# =======================================================================================
# Analyze
# =======================================================================================

function Add-DFSAnalysis {
    param(
        [PSCustomObject]$Cfg,
        [PSCustomObject]$Context,
        [PSCustomObject]$Row,
        [switch]$WithPerFileProof
    )

    $add = {
        param($name, $value)
        $Row | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force
    }

    & $add 'Verdict'          'REVIEW'
    & $add 'YearsIdle'        $null
    & $add 'AgeIsLowerBound'  $null
    & $add 'NewestAccessed'   $null
    & $add 'NewestModified'   $null
    & $add 'BytesUsed'        $null
    & $add 'FileCount'        $null
    & $add 'SubdirCount'      $null
    & $add 'AnalyticsState'   $null
    & $add 'AccessTimeEnabled' $null
    & $add 'FsaLabels'        $null
    & $add 'ProofComplete'    $null
    & $add 'VerdictReasons'   $null

    if (-not $Row.Resolved -or -not $Row.Volume) {
        & $add 'VerdictReasons' 'Target not resolved — nothing to analyze.'
        return $Row
    }

    $vol = Get-NaVolume -Context $Context -VolumeName $Row.Volume -Vserver $Row.Vserver
    if ($vol) {
        & $add 'AnalyticsState'    $vol.AnalyticsState
        & $add 'AccessTimeEnabled' $vol.AccessTimeEnabled
    }

    # Measure the object that would actually be DELETED, not its parent.
    #
    # This used to use $Row.Qtree, which is the parent qtree for a subfolder target. Every
    # subfolder row then inherited the whole qtree's figures: three sibling subfolder rows under
    # one parent all reported an identical 1.55 TiB / 1,229,682 files / 79,728 dirs —
    # the parent qtree's totals — and all three came back ACTIVE because that qtree is busy.
    #
    # Reading ACTIVE for an empty subfolder is merely wrong. The reverse is dangerous: a COLD
    # qtree containing one hot subfolder would hand that subfolder the qtree's IMMEDIATE verdict
    # and mark live data for deletion. DeleteRelPath is the path the delete primitives act on, so
    # it is the only correct thing to measure. For a qtree target the two are identical, so
    # nothing changes there; empty means measure the volume root.
    $fsaPath = if ($Row.DeleteRelPath) { $Row.DeleteRelPath }
               elseif ($Row.Qtree)     { $Row.Qtree }
               else                    { '' }
    $analytics = if ($vol) { Get-NaDirectoryAnalytics -Context $Context -VolumeUuid $vol.Uuid -Path $fsaPath } else { $null }

    if ($analytics) {
        & $add 'BytesUsed'   $analytics.BytesUsed
        & $add 'FileCount'   $analytics.FileCount
        & $add 'SubdirCount' $analytics.SubdirCount
        & $add 'FsaLabels'   ($analytics.RawLabels -join '|')
    }

    $perFile = $null
    if ($WithPerFileProof -and $vol -and $analytics) {
        Write-DFSLog "  Collecting per-file timestamps for '$($Row.DfsPath)' (this walks the tree)..." 'STEP'
        $perFile = Get-NaNewestTimestamp -Context $Context -VolumeUuid $vol.Uuid -Path $fsaPath `
                        -MaxRecords ([int]$Cfg.Clean.FileScanMaxRecords)
        & $add 'NewestAccessed' $perFile.NewestAccessed
        & $add 'NewestModified' $perFile.NewestModified
        & $add 'ProofComplete'  $perFile.Complete
    }

    $verdictArgs = @{
        Volume         = $vol
        Analytics      = $analytics
        PerFile        = $perFile
        CandidateYears = $Cfg.CandidateYears
        ImmediateYears = $Cfg.ImmediateYears
    }
    if ($Cfg.RequireProof) { $verdictArgs['RequirePerFileProof'] = $true }

    $v = Get-DFSCleanupVerdict @verdictArgs

    & $add 'Verdict'         $v.Verdict
    & $add 'YearsIdle'       $v.YearsIdle
    & $add 'AgeIsLowerBound' $v.IsLowerBound
    & $add 'VerdictReasons'  (@($v.Reasons) -join ' ')

    # MarkedForDeletion is the machine's proposal. Approved is deliberately left blank for a
    # person to fill in — -Mode Delete will not act on any row where it is empty.
    & $add 'MarkedForDeletion' ($v.Verdict -in @('IMMEDIATE', 'CANDIDATE', 'EMPTY'))
    & $add 'Approved'          ''
    & $add 'ApprovedBy'        ''
    & $add 'ApprovedDate'      ''

    $null = Add-DFSTrackerFields -Context $Context -Row $Row -Volume $vol -Analytics $analytics

    return $Row
}

function Get-DFSSymlinkMapAndAnomalies {
    <#
    .SYNOPSIS
        Build the Symlink_Map and Anomalies row sets for the workbook.
    .DESCRIPTION
        Both sheets used to be produced by a one-off pass that was never part of this script, so
        they froze the moment it finished while the mail told four people the workbook refreshes
        daily. A symlink added or removed on the cluster never showed up.

        Reuses the container scan already done for the symlink index — that scan is the slowest
        step in a run, so it must not happen twice. Returns $null when the scan is unavailable,
        which the caller treats as "leave the existing sheets alone" rather than "empty them".
    #>
    param([PSCustomObject]$Cfg, [PSCustomObject]$Context)

    # Force the index (and therefore the container scan) to exist.
    $null = Get-DFSSymlinkFileIndex -Cfg $Cfg -Context $Context
    if (-not $script:SymlinkContainers) {
        Write-DFSLog '  Container scan unavailable — Symlink_Map and Anomalies not rebuilt.' 'WARN'
        return $null
    }

    $wlMap = @{}
    $shareMap = @{}
    $qtreeSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    try {
        foreach ($w in @(Get-NcCifsSymlink -VserverContext $Cfg.Vserver -ErrorAction Stop)) {
            $wlMap["$($w.UnixPath)".Trim('/').ToLowerInvariant()] = $w.ShareName
        }
        foreach ($s in @(Get-NcCifsShare -VserverContext $Cfg.Vserver -ErrorAction Stop)) {
            if (-not $shareMap.ContainsKey($s.ShareName)) { $shareMap[$s.ShareName] = $s }
        }
        foreach ($q in @(Get-NcQtree -VserverContext $Cfg.Vserver -ErrorAction Stop)) {
            if ($q.Qtree) { [void]$qtreeSet.Add("$($q.Volume)/$($q.Qtree)") }
        }
    }
    catch {
        Write-DFSLog "  Could not read the widelink/share/qtree tables: $($_.Exception.Message)" 'WARN'
        return $null
    }

    $cifsAlias = $null
    if ($Cfg.PSObject.Properties.Name -contains 'CifsAlias') { $cifsAlias = $Cfg.CifsAlias }

    $map = @(Resolve-NaSymlinkChain -Containers $script:SymlinkContainers -WidelinkMap $wlMap `
                -ShareMap $shareMap -QtreeSet $qtreeSet -CifsAlias $cifsAlias)
    $anom = @(Get-DFSAnomaly -SymlinkMap $map -WidelinkMap $wlMap)

    Write-DFSLog "  Symlink map: $($map.Count) file(s); anomalies: $($anom.Count)." 'OK'
    return [PSCustomObject]@{ Map = $map; Anomalies = $anom }
}

function Add-DFSTrackerFields {
    <#
    .SYNOPSIS
        Produce the five human-facing columns the CAB1 tracker carries that the analysis
        pipeline does not: ContentMeasured, DfsEnabled, ClusterCheck, Status, AutoNotes.
    .DESCRIPTION
        These existed only in the workbook, filled by a one-off pass that was never part of
        this script — which is why a daily run could not refresh the tracker and had to append
        a dated sheet instead. They are computed here so the workbook is a product of the run.

        ContentMeasured is a DIRECT measurement, deliberately not FSA. FSA answers "how much
        does this hold" from a scan that may be hours old or still initializing; the tracker's
        question is "is there anything in here right now". Six rows carried a recorded size that
        direct measurement contradicted (Utils recorded 2.47 GiB, measured empty), which is the
        whole reason the column exists. The probe is first-page-only: proving non-empty needs
        one entry, not a full enumeration.
    #>
    param(
        [PSCustomObject]$Context,
        [PSCustomObject]$Row,
        [PSCustomObject]$Volume,
        [PSCustomObject]$Analytics
    )

    $add = {
        param($name, $value)
        $Row | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force
    }

    # --- Content (measured) -------------------------------------------------------------
    $content = $null
    if ($Volume -and $Row.Resolved) {
        $probePath = if ($Row.DeleteRelPath) { $Row.DeleteRelPath } elseif ($Row.Qtree) { $Row.Qtree } else { '' }
        try {
            $entries = @(Get-NaDirectoryEntries -Context $Context -VolumeUuid $Volume.Uuid `
                            -Path $probePath -MaxRecords 100 -FirstPageOnly)
            if ($entries.Count -eq 0) {
                $content = 'EMPTY - 0 entries'
            }
            elseif ($Analytics -and $null -ne $Analytics.FileCount) {
                $content = "$($Analytics.FileCount) files / $($Analytics.SubdirCount) dirs (FSA)"
            }
            else {
                # First page only, so this is a floor, not a total. Say so rather than imply a count.
                $content = "$($entries.Count)+ entries"
            }
        }
        catch { $content = $null }
    }
    # A gone target leaves this cell alone ($content stays $null) so the last measured content
    # survives as history. Overwriting it with 'no longer exists' would destroy the record of
    # what was actually removed, which is the one thing worth keeping after a deletion.
    & $add 'ContentMeasured' $content

    # --- DFS Enabled --------------------------------------------------------------------
    # Reachable through the namespace, i.e. a widelink table entry AND a symlink file exist.
    # An orphan qtree holds data but no namespace path leads to it.
    $dfsEnabled = $null
    if ($Row.OrphanState -eq 'FullyGone') { $dfsEnabled = $false }
    elseif ($Row.Resolved) {
        $dfsEnabled = ($Row.OrphanState -eq 'Live' -and [int]$Row.SymlinkFileCount -gt 0)
    }
    & $add 'DfsEnabled' $dfsEnabled

    # --- ClusterCheck -------------------------------------------------------------------
    $check = switch ($Row.OrphanState) {
        'Live'        { 'Live in the DFS namespace - share, qtree and symlink file all present' }
        'OrphanQtree' { 'Qtree exists but no share and no namespace path reaches it' }
        'OrphanShare' { 'Share exists but no widelink or symlink file reaches it' }
        'FullyGone'   { 'Nothing left on the cluster - share, qtree and symlink all absent' }
        default       {
            if ($Row.Resolved) { 'Resolved against the cluster' } else { 'Not resolved - no cluster object matched' }
        }
    }
    if ($Row.Resolved -and -not $Row.VolumeExists) { $check = 'Volume not found on this SVM' }
    & $add 'ClusterCheck' $check

    # --- Last Accessed / Last Modified --------------------------------------------------
    # What a reader actually wants from this workbook. Two sources, and the column says which:
    #   - with -PerFileProof, real per-file timestamps -> an exact date
    #   - otherwise the newest non-empty FSA histogram bucket -> a period label ('2025', '2026-W31')
    # The bucket is a PERIOD, not a date, so it is never dressed up as one.
    #
    # Access carries a caveat the reader must see: listing a directory updates that directory's
    # own accessed_time, and FSA counts the directory inode in the histogram. On a target whose
    # real data is much older, the newest access bucket can therefore be this scan's own
    # footprint. When access looks current but modify is materially older, that is flagged inline
    # rather than silently presented as a genuine access.
    $lastAcc = $null; $lastMod = $null
    if ($Row.PSObject.Properties.Name -contains 'NewestAccessed' -and $Row.NewestAccessed) {
        $lastAcc = ([datetime]$Row.NewestAccessed).ToString('yyyy-MM-dd')
    }
    if ($Row.PSObject.Properties.Name -contains 'NewestModified' -and $Row.NewestModified) {
        $lastMod = ([datetime]$Row.NewestModified).ToString('yyyy-MM-dd')
    }
    if ((-not $lastAcc -or -not $lastMod) -and $Analytics -and $Analytics.Buckets) {
        try {
            $accS = Get-NaBucketSummary -Buckets $Analytics.Buckets -Dimension 'Accessed' -Now (Get-Date)
            $modS = Get-NaBucketSummary -Buckets $Analytics.Buckets -Dimension 'Modified' -Now (Get-Date)
            if (-not $lastMod -and $modS.NewestLabel) { $lastMod = "$($modS.NewestLabel) (FSA period)" }
            if (-not $lastAcc -and $accS.NewestLabel) {
                $lastAcc = "$($accS.NewestLabel) (FSA period)"
                # Access newer than modify by more than a year, on a target with real content:
                # the recent access bucket is almost certainly our own directory read.
                if ($null -ne $accS.YearsSinceNewest -and $null -ne $modS.YearsSinceNewest -and
                    ($modS.YearsSinceNewest - $accS.YearsSinceNewest) -gt 1) {
                    $lastAcc += ' - may include this scan'
                }
            }
        }
        catch { }
    }
    # HISTORY IS PROTECTED. Once a target is gone there is nothing left to measure, so writing
    # 'n/a - gone' here would erase the last known figures — exactly the evidence you want AFTER
    # a deletion: how big it was and when it was last touched. $null leaves the cell alone, so
    # whatever the final successful measurement recorded stays in the workbook for good.
    $isGone = ($Row.Verdict -eq 'GONE' -or $Row.OrphanState -eq 'FullyGone')
    if ($isGone) { $lastAcc = $null; $lastMod = $null }
    & $add 'LastAccessedText' $lastAcc
    & $add 'LastModifiedText' $lastMod

    # --- Size (GB), measured ------------------------------------------------------------
    # Re-verified against the cluster on every run. This column used to be hand-maintained and
    # went stale badly: the tracker recorded 2.47 GiB against a qtree that measures zero, and
    # 1.55 TiB against three paths that do not exist at all. The original figures survive in the
    # '.bak-<stamp>.xlsx' backups and in 'Volumes or Qtree to Delete - ORIGINAL.xlsx'.
    # Same history rule as Last Accessed / Last Modified: a gone target leaves the cell untouched
    # so the last measured size survives as the record of what was removed.
    $sizeText = $null
    if ($isGone) {
        $sizeText = $null
    }
    elseif ($Analytics -and $null -ne $Analytics.BytesUsed) {
        $b = [double]$Analytics.BytesUsed
        # No files and no subdirectories means the bytes are the directory inode, not content.
        if ([int64]$Analytics.FileCount -eq 0 -and [int64]$Analytics.SubdirCount -eq 0) { $sizeText = '0 (empty)' }
        elseif ($b -ge 1TB) { $sizeText = "$([math]::Round($b / 1TB, 2)) TiB" }
        elseif ($b -ge 1GB) { $sizeText = "$([math]::Round($b / 1GB, 2)) GiB" }
        elseif ($b -ge 1MB) { $sizeText = "$([math]::Round($b / 1MB, 2)) MiB" }
        else                { $sizeText = "$([int64]$b) B" }
    }
    & $add 'SizeMeasured' $sizeText

    # --- Status -------------------------------------------------------------------------
    # The tracker's own vocabulary, which is NOT the Verdict vocabulary. Verdict answers "how
    # old is it"; Status answers "what state is this object in". Keeping them separate is
    # deliberate: DELETED is a fact about the cluster, CANDIDATE is an opinion about age.
    $status = if ($Row.OrphanState -eq 'FullyGone' -or $Row.Verdict -eq 'GONE') { 'GONE' }
              elseif ($Row.Verdict -eq 'EMPTY' -or $content -eq 'EMPTY - 0 entries') { 'EMPTY' }
              elseif ($Row.Verdict -eq 'ACTIVE') { 'ACTIVE' }
              elseif ($Row.Verdict -in @('IMMEDIATE', 'CANDIDATE')) { 'INVESTIGATE' }
              elseif ($Row.Verdict -in @('NO_ANALYTICS', 'NO_ATIME')) { 'PENDING SCAN' }
              else { 'REVIEW' }
    & $add 'Status' $status

    # --- AutoNotes ----------------------------------------------------------------------
    $notes = [System.Collections.Generic.List[string]]::new()
    if ($isGone) {
        # Says out loud that four columns are frozen, so nobody reads a stale size as current.
        $notes.Add('Gone from the cluster. Size (GB), Last Accessed, Last Modified and ' +
                   'Content (measured) are the LAST MEASURED values, kept as the record of what was removed.')
    }
    if ($content -eq 'EMPTY - 0 entries' -and $Row.QuotaUsed -and $Row.QuotaUsed -notmatch '^0(\.0+)?\s*(B|GB|TB)?$') {
        $notes.Add("Quota reports $($Row.QuotaUsed) used but direct measurement finds the target empty - trust the measurement.")
    }
    if ([int]$Row.WidelinkCount -gt 1) {
        $notes.Add("Share is reached by $($Row.WidelinkCount) widelinks ($($Row.SharedWithLinks)) - removing the share breaks the others.")
    }
    if ([int]$Row.SymlinkFileCount -gt 1) {
        $notes.Add("$($Row.SymlinkFileCount) symlink files point at this link - every one must go to retire it.")
    }
    if ($Row.DeleteMethod -eq 'Directory') {
        $notes.Add('Target is a plain directory inside a qtree - a qtree delete would take its siblings.')
    }
    if ($Row.AccessTimeEnabled -eq $false) {
        $notes.Add('Access-time tracking is OFF on this volume, so idle-time evidence is not trustworthy.')
    }
    if ($Row.AnalyticsState -and $Row.AnalyticsState -ne 'on') {
        $notes.Add("FSA state '$($Row.AnalyticsState)' - age figures are unavailable or incomplete until the scan finishes.")
    }
    & $add 'AutoNotes' (($notes) -join ' ')

    # --- FSA State (human text) ---------------------------------------------------------
    # 'initializing' alone tells the reader nothing about whether to wait ten minutes or a day,
    # so the scan percentage is folded in when the cluster reports one.
    $fsaText = $Row.AnalyticsState
    if ($Volume) {
        $progress = $null
        if ($Volume.Raw.PSObject.Properties.Name -contains 'analytics' -and
            $Volume.Raw.analytics.PSObject.Properties.Name -contains 'scan_progress') {
            $progress = $Volume.Raw.analytics.scan_progress
        }
        if ($Volume.AnalyticsState -eq 'initializing' -and $null -ne $progress) {
            $fsaText = "scanning $($Volume.Name) ($progress%)"
        }
        elseif ($Volume.AnalyticsState) {
            $fsaText = $Volume.AnalyticsState
        }
    }
    & $add 'FsaStateText' $fsaText

    return $Row
}

# =======================================================================================
# Delete
# =======================================================================================

function Test-DeletionAllowed {
    <#
    .SYNOPSIS
        Two independent gates before anything is removed: a machine verdict, and a human approval.
    .DESCRIPTION
        The verdict says a target LOOKS deletable. The Approved column says a person decided it
        IS. Neither substitutes for the other, and -Force bypasses neither — it only skips the
        typed-name prompt. To approve, open the report CSV (or the updated workbook) and set
        Approved to YES on the rows that were signed off.
    #>
    param([PSCustomObject]$Cfg, [PSCustomObject]$Row, [string[]]$Approved, [hashtable]$VerdictMap)

    $key = $Row.DfsPath.Trim().ToLowerInvariant()
    if (-not $VerdictMap.ContainsKey($key)) {
        return @{ Allowed = $false; Reason = "No stored verdict for '$($Row.DfsPath)' in the verdict file. Run -Mode Report first." }
    }
    $stored = $VerdictMap[$key]

    if ($stored.Verdict -notin $Approved) {
        return @{ Allowed = $false; Reason = "Stored verdict is '$($stored.Verdict)', which is not in the approved set ($($Approved -join ', '))." }
    }

    $approvalRaw = if ($stored.PSObject.Properties.Name -contains 'Approved') { [string]$stored.Approved } else { '' }
    if ($approvalRaw.Trim() -notmatch '^(?i)(yes|y|true|1|approved)$') {
        $shown = if ([string]::IsNullOrWhiteSpace($approvalRaw)) { '<blank>' } else { $approvalRaw }
        return @{ Allowed = $false; Reason = "Not approved (Approved='$shown'). Set Approved=YES in the verdict file for this row after sign-off." }
    }

    return @{
        Allowed = $true
        Reason  = "Verdict '$($stored.Verdict)' (idle $($stored.YearsIdle)y) and Approved='$($approvalRaw.Trim())'."
        Stored  = $stored
    }
}

function Import-DFSOverrideManifest {
    <#
    .SYNOPSIS
        Load and validate the signed-by-hand manifest that authorises unattended deletion.
    .DESCRIPTION
        The interactive challenge cannot work without a console, so bulk/unattended deletion needs
        a different kind of evidence: a file the operator had to author deliberately, today, under
        their own account, naming every path individually.

        Four checks, ALL required. Any failure returns $null and deletion falls back to the
        interactive gate (which then refuses in a non-interactive session):

          1. Override    — the top-level key must be exactly 'OVERRIDE' (upper case).
          2. Date        — must be TODAY'S local date. This is what stops a manifest being written
                           once and left in place to authorise deletions forever. Yesterday's file
                           is worthless by design.
          3. Operator    — must match the Windows identity actually running the script. A manifest
                           authored by someone else does not authorise your run, and yours does not
                           authorise theirs. This is the "not someone else" requirement.
          4. Paths       — each path carries its OWN 'OVERRIDE' value. A path absent from the
                           manifest is not authorised, even if every other path in the run is.
                           There is deliberately no wildcard and no "all" keyword.

        Expected shape:

            {
              "Override": "OVERRIDE",
              "Date":     "<today, yyyy-MM-dd>",
              "Operator": "<DOMAIN>\\<your-account>",
              "Paths": {
                "\\\\<ns>\\dfs\\<Link>\\<Sub>": "OVERRIDE",
                "\\\\<ns>\\dfs\\<OtherLink>":   "OVERRIDE"
              }
            }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-DFSLog "Override manifest '$Path' not found." 'ERROR'
        return $null
    }

    try { $m = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop }
    catch {
        Write-DFSLog "Override manifest '$Path' is not valid JSON: $($_.Exception.Message)" 'ERROR'
        return $null
    }

    $names = @($m.PSObject.Properties.Name)
    foreach ($req in @('Override', 'Date', 'Operator', 'Paths')) {
        if ($names -notcontains $req) {
            Write-DFSLog "Override manifest is missing the '$req' key." 'ERROR'
            return $null
        }
    }

    # 1 — the literal keyword, case-sensitive on purpose.
    if ([string]$m.Override -cne 'OVERRIDE') {
        Write-DFSLog "Override manifest key must be exactly 'OVERRIDE' (upper case), found '$($m.Override)'." 'ERROR'
        return $null
    }

    # 2 — today, not 'recently'.
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $stated = try { ([datetime]$m.Date).ToString('yyyy-MM-dd') } catch { [string]$m.Date }
    if ($stated -ne $today) {
        Write-DFSLog "Override manifest is dated '$stated' but today is '$today'. A manifest only authorises the day it was written." 'ERROR'
        return $null
    }

    # 3 — the account actually running this, not the one the file claims to be for.
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $stateds = ([string]$m.Operator).Trim()
    # Accept DOMAIN\user or bare user, case-insensitively — the check is identity, not formatting.
    $meShort = ($me -split '\\')[-1]
    $opShort = ($stateds -split '\\')[-1]
    if ($opShort -ine $meShort) {
        Write-DFSLog "Override manifest names operator '$stateds' but this run is '$me'. A manifest does not authorise another account." 'ERROR'
        return $null
    }
    if ($stateds -match '\\' -and $stateds -ine $me) {
        Write-DFSLog "Override manifest operator '$stateds' does not match '$me' exactly." 'ERROR'
        return $null
    }

    # 4 — per-path opt-in.
    $allowed = @{}
    foreach ($p in $m.Paths.PSObject.Properties) {
        if ([string]$p.Value -ceq 'OVERRIDE') {
            $allowed[([string]$p.Name).Trim().TrimEnd('\').ToLowerInvariant()] = $true
        }
        else {
            Write-DFSLog "  Manifest path '$($p.Name)' has value '$($p.Value)', not 'OVERRIDE' — not authorised." 'WARN'
        }
    }
    if ($allowed.Count -eq 0) {
        Write-DFSLog 'Override manifest authorises no paths.' 'ERROR'
        return $null
    }

    Write-DFSLog "Override manifest accepted: operator '$me', dated $stated, $($allowed.Count) path(s) authorised." 'OK'
    return $allowed
}

function Test-DFSInteractiveConsole {
    # Its own function so the offline tests can stub it. Both halves are needed: UserInteractive
    # is false under a service or scheduled task, and IsInputRedirected catches `... | pwsh -File`
    # and CI, where Read-Host returns immediately instead of waiting for a person.
    return ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected)
}

function Confirm-DFSDeletion {
    <#
    .SYNOPSIS
        Three-challenge interactive gate, once per target, before anything is removed.
    .DESCRIPTION
        A [Y/N] prompt you have answered forty times is not a decision any more, and
        '[A] Yes to All' turns one keystroke into every remaining deletion. This replaces that
        with three challenges that cannot be answered from muscle memory:

          1. Type YES.
          2. Answer a randomly generated multiplication. The numbers change every call, so the
             answer cannot be pre-loaded and the hand cannot move before the brain does.
          3. Type the full DFS path being deleted.

        Design decisions worth not undoing:

        - -Force does NOT bypass this. Every other prompt in the script yields to -Force, which
          is exactly how a gate stops existing in practice. If a caller needs unattended deletion
          it has to be a separate, deliberately named mechanism, not a flag that already means
          "skip the FSA warning".
        - A non-interactive session REFUSES. It does not proceed. There is no console to
          challenge, so the safe answer is no.
        - One wrong answer refuses THIS target and returns; the run continues to the next path.
          No retries: a second attempt at the same sum is just the autopilot the gate exists to
          defeat. Re-run the script if it was a genuine slip.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Row,
        [switch]$IncludeBackingStorage,
        # Validated manifest from Import-DFSOverrideManifest: normalised path -> $true.
        [hashtable]$Override,
        # Set for -ForceDeletePath targets: deleting on a person's word, not on age evidence.
        # Adds a fourth challenge naming who authorised it, and refuses manifest authorisation.
        [switch]$ManagerAuthorised
    )

    # A valid manifest replaces the challenge for the paths it names — and only those. The
    # deliberation happened when the operator wrote the file: today's date, their own account,
    # every path spelled out. Nothing here is skippable by a flag.
    #
    # But NOT for a -ForceDeletePath target. That already sets aside the age evidence; letting a
    # file also set aside the human confirmation would stack two bypasses and leave a deletion
    # with no evidence and nobody present. One bypass at a time.
    if ($Override -and $ManagerAuthorised) {
        Write-DFSLog "  Override manifest does not apply to a -ForceDeletePath target — confirming interactively." 'WARN'
    }
    elseif ($Override) {
        $key = ([string]$Row.DfsPath).Trim().TrimEnd('\').ToLowerInvariant()
        if ($Override.ContainsKey($key)) {
            Write-DFSLog "  Authorised by override manifest for '$($Row.DfsPath)'." 'OK'
            return $true
        }
        Write-DFSLog "  '$($Row.DfsPath)' is NOT listed in the override manifest — falling back to the interactive challenge." 'WARN'
    }

    if (-not (Test-DFSInteractiveConsole)) {
        Write-DFSLog '  REFUSED: deletion needs an interactive console for the confirmation challenge.' 'ERROR'
        return $false
    }

    # -Mode Delete does not run Add-DFSAnalysis — the evidence came from the earlier Report run,
    # not from now — so a row legitimately arrives here without the analysis fields. Under
    # StrictMode, reading one directly is a terminating error, and a line that only prints
    # context must never be the thing that kills a confirmed deletion.
    $show = {
        param($name, $fallback)
        if (($Row.PSObject.Properties.Name -contains $name) -and
            -not [string]::IsNullOrWhiteSpace([string]$Row.$name)) { $Row.$name } else { $fallback }
    }

    $target = $Row.DfsPath
    $storage = if ($IncludeBackingStorage) {
        "$($Row.DeleteMethod) '$($Row.DeleteRelPath)' on volume '$($Row.Volume)'"
    }
    else { 'NOT included (link and share only)' }

    Write-Host ''
    Write-Host '  ============================================================' -ForegroundColor Red
    Write-Host '   IRREVERSIBLE DELETION — CONFIRM' -ForegroundColor Red
    Write-Host '  ============================================================' -ForegroundColor Red
    Write-Host "   DFS path       : $target"
    Write-Host "   Share          : $($Row.Share)"
    Write-Host "   Widelink       : $($Row.UnixPath)"
    Write-Host "   Symlink file   : $($Row.SymlinkFilePath)"
    Write-Host "   Backing storage: $storage" -ForegroundColor $(if ($IncludeBackingStorage) { 'Red' } else { 'Yellow' })
    Write-Host "   Verdict        : $(& $show 'Verdict' 'n/a (not analysed this run)')   Content: $(& $show 'ContentMeasured' 'not measured')"
    if ([int]$Row.WidelinkCount -gt 1) {
        Write-Host "   NOTE: share is reached by $($Row.WidelinkCount) widelinks — the share will be PRESERVED." -ForegroundColor Yellow
    }
    if ($ManagerAuthorised) {
        Write-Host '   BASIS: a person''s decision, NOT age evidence. No 3-year proof was required.' -ForegroundColor Magenta
    }
    Write-Host '  ------------------------------------------------------------' -ForegroundColor Red

    $total = if ($ManagerAuthorised) { 4 } else { 3 }

    # 1 — YES
    if ((Read-Host "   [1/$total] Type YES to continue").Trim() -notmatch '^(?i)yes$') {
        Write-DFSLog '  Confirmation step 1 failed — nothing deleted.' 'WARN'
        return $false
    }

    # 2 — arithmetic. Two digits multiplied: enough to force a pause, not enough to be a puzzle.
    $a = Get-Random -Minimum 3 -Maximum 20
    $b = Get-Random -Minimum 3 -Maximum 20
    $answer = (Read-Host "   [2/$total] Solve: $a x $b = ").Trim()
    if ($answer -ne [string]($a * $b)) {
        Write-DFSLog "  Confirmation step 2 failed (answered '$answer', expected $($a * $b)) — nothing deleted." 'WARN'
        return $false
    }

    # 3 — the full path. Quotes stripped because pasting from Explorer brings them along, and
    # case/trailing-slash ignored because Windows paths are not case-sensitive — the point is
    # that the whole path had to be typed, not that it was typed pedantically.
    $typed = (Read-Host "   [3/$total] Type the FULL path to delete").Trim().Trim('"').Trim("'").TrimEnd('\')
    if ($typed -ne ([string]$target).Trim().TrimEnd('\')) {
        Write-DFSLog "  Confirmation step 3 failed (typed '$typed') — nothing deleted." 'WARN'
        return $false
    }

    # 4 — only for -ForceDeletePath. The age rule is the normal justification and it writes itself
    # into the verdict CSV. When a person overrules it, the justification is that person's name,
    # and it has to be captured or the run log records a deletion nobody can account for later.
    # Free text on purpose: the point is attribution, not validating a name against a directory.
    if ($ManagerAuthorised) {
        $who = (Read-Host "   [4/$total] Who authorised this deletion? (name / ticket)").Trim()
        if ($who.Length -lt 3) {
            Write-DFSLog '  Confirmation step 4 failed (no authoriser given) — nothing deleted.' 'WARN'
            return $false
        }
        $Row | Add-Member -NotePropertyName 'AuthorisedBy' -NotePropertyValue $who -Force
        Write-DFSLog "  '$target' deleted on the authority of '$who', recorded by $([Security.Principal.WindowsIdentity]::GetCurrent().Name)." 'WARN'
    }

    Write-DFSLog "  Confirmed by operator for '$target' ($total/$total challenges passed)." 'OK'
    return $true
}

function Remove-DFSTarget {
    param(
        [PSCustomObject]$Cfg,
        [PSCustomObject]$Row,
        [PSCustomObject]$RestContext,
        [PSCredential]$NcCredential,
        [switch]$IncludeBackingStorage,
        [switch]$NoPrompt,
        # Set when Confirm-DFSDeletion has already passed for this target.
        [switch]$ChallengePassed
    )

    # The three-challenge gate has been answered for this whole target, so the per-object
    # [Y/A/N] prompts underneath are removed deliberately. Six numb prompts after one real
    # decision is how '[A] Yes to All' gets pressed. ShouldProcess is still CALLED, so -WhatIf
    # keeps working — only the prompting is suppressed, and only in this function's scope.
    if ($ChallengePassed) { $ConfirmPreference = 'None' }

    $svm = $Row.Vserver

    # ---- Phase 1: share, widelink, leftover symlink file (recoverable — data untouched) ----
    Write-DFSLog "PHASE 1 — share and links for '$($Row.DfsPath)'" 'STEP'

    # A share targeted by more than one widelink is still in use by the other link(s). Removing
    # this DFS link is fine; removing the share underneath it is not. Phase 2 is skipped too,
    # because the storage is still reachable through the surviving link.
    $shareIsShared = ($Row.WidelinkCount -and [int]$Row.WidelinkCount -gt 1)

    if ($shareIsShared) {
        Write-DFSLog "  SHARE PRESERVED: '$($Row.Share)' is targeted by $($Row.WidelinkCount) widelinks ($($Row.SharedWithLinks))." 'WARN'
        Write-DFSLog "  Only this DFS link will be removed. Backing storage is still reachable via the other link(s)." 'WARN'
    }
    elseif ($Row.Share -and $Row.ShareExists) {
        if ($PSCmdlet.ShouldProcess("CIFS share '$($Row.Share)' on '$svm'", 'Remove')) {
            Remove-NcCifsShare -ShareName $Row.Share -VserverContext $svm -Confirm:$false
            Write-DFSLog "  Removed CIFS share '$($Row.Share)'." 'OK'
        }
    }
    else {
        Write-DFSLog "  No CIFS share to remove (share '$($Row.Share)' not present)." 'WARN'
    }

    if (-not [string]::IsNullOrWhiteSpace($Row.UnixPath) -and $Row.UnixPath -ne 'none') {
        $symlink = Get-NcCifsSymlink -UnixPath $Row.UnixPath -VserverContext $svm -ErrorAction SilentlyContinue
        if ($symlink) {
            if ($PSCmdlet.ShouldProcess("CIFS widelink '$($Row.UnixPath)' on '$svm'", 'Remove')) {
                $symlink | Remove-NcCifsSymlink -VserverContext $svm -Confirm:$false
                Write-DFSLog "  Removed CIFS widelink '$($Row.UnixPath)'." 'OK'
            }
        }
        else {
            Write-DFSLog "  No CIFS widelink at '$($Row.UnixPath)'." 'WARN'
        }
    }

    # Removing the widelink table entry leaves the symlink FILE behind in its container volume,
    # and the DFS root keeps a dead entry. The path comes from the discovered index
    # (SymlinkFilePath), never from Row.Link — Link is fabricated from the input UNC by
    # Get-DFSNameSpaceRoot and points at the wrong container whenever the file lives elsewhere.
    if ([string]::IsNullOrWhiteSpace($Row.SymlinkFilePath)) {
        if (-not [string]::IsNullOrWhiteSpace($Row.Link) -and $Row.Link -ne 'none') {
            Write-DFSLog "  No symlink file was located for this widelink — nothing to unlink. (Not using Link '$($Row.Link)': it is derived from the UNC path, not discovered.)" 'WARN'
        }
    }
    elseif ($shareIsShared) {
        # A share reached by SEVERAL WIDELINK ENTRIES (e.g. Inst$ via /Inst/, /ITInst/,
        # /OracleInst/) has other, distinct links depending on it. Leave its files alone.
        Write-DFSLog "  Symlink file(s) PRESERVED ($($Row.SymlinkFilePath)) — the share is reached by $($Row.WidelinkCount) separate widelinks." 'WARN'
    }
    else {
        # Several symlink FILES sharing ONE target are just multiple namespace routes to the
        # same link (e.g. /DFSROOT_A/APP1 and /DFSROOT_B/APP1 both -> /APP1/). Retiring the link means
        # removing all of them; leaving one behind leaves a dead entry in that DFS root.
        # This is NOT the same as several widelinks pointing at one share, handled above.
        if ($Row.SymlinkFileCount -and [int]$Row.SymlinkFileCount -gt 1) {
            Write-DFSLog "  $($Row.SymlinkFileCount) symlink files route to this one widelink — all will be removed: $($Row.SymlinkFilePath)" 'WARN'
        }
        # SSH goes to the CLUSTER management name, not to a node. Node names such as
        # 'a1k-prd-01' are cluster-internal and generally do not resolve in DNS — connecting to
        # one produced 'No such host is known' and left the file behind. ClusterAlias is the same
        # name Connect-NcController already used successfully, so it is known to resolve.
        #
        # The node is then named explicitly in 'run -node <node>'. Nodeshell 'rm' only works on
        # the node that HOSTS the volume; every other node answers 'Volume is not known or has
        # been moved'. A FlexVol lives in exactly one aggregate and an aggregate is owned by
        # exactly one node, so the aggregate identifies the host precisely — no fan-out, no
        # per-node noise to read past. '-node *' is kept only as a fallback for the narrow case
        # where the volume moved between this lookup and the command.
        #
        # Success is VERIFIED with 'ls' rather than inferred from rm's silence: a successful
        # nodeshell rm prints nothing, and so does a command that never reached the right node.
        $sshTarget = $Cfg.ClusterAlias
        foreach ($sp in @($Row.SymlinkFilePath -split ' ; ')) {
            $rel = $sp.Trim().TrimStart('/')
            $containerVol = ($rel -split '/')[0]
            $containerObj = Get-NcVol -Name $containerVol -VserverContext $svm -ErrorAction SilentlyContinue
            if (-not $containerObj) {
                Write-DFSLog "  Container volume '$containerVol' not found — skipping symlink file cleanup." 'WARN'
                continue
            }

            # VolumeIdAttributes.Node is not populated by the ZAPI unless explicitly requested,
            # so the owning node comes from the aggregate the volume sits in.
            $owner = @((Get-NcAggr $containerObj.Aggregate -ErrorAction SilentlyContinue).Nodes) |
                     Where-Object { $_ } | Select-Object -First 1
            if (-not $owner) {
                Write-DFSLog "  Could not determine which node hosts volume '$containerVol' — falling back to all nodes." 'WARN'
                $owner = '*'
            }

            $nodeshell = { param($verb, $node) 'run -node {0} -command "priv set diag; {1} /vol/{2}"' -f $node, $verb, $rel }
            $readOut = {
                param($resp)
                (@($resp) | ForEach-Object {
                    if ($null -eq $_) { '' }
                    elseif ($_.PSObject.Properties.Name -contains 'Value') { [string]$_.Value }
                    else { [string]$_ }
                }) -join "`n"
            }

            if ($PSCmdlet.ShouldProcess("Node '$owner' file '/vol/$rel' (via cluster '$sshTarget')", 'Remove leftover symlink file via nodeshell rm')) {
                try {
                    $null  = Invoke-NcSsh -Name $sshTarget -Command (& $nodeshell 'rm' $owner) -Credential $NcCredential -ErrorAction Stop
                    $after = & $readOut (Invoke-NcSsh -Name $sshTarget -Command (& $nodeshell 'ls' $owner) -Credential $NcCredential -ErrorAction Stop)

                    # 'Volume is not known' back from the node we deliberately targeted means the
                    # volume moved after the aggregate lookup. That is the one case the fan-out
                    # handles better, so retry once across all nodes rather than fail.
                    if ($owner -ne '*' -and $after -match 'Volume is not known') {
                        Write-DFSLog "  Volume '$containerVol' is no longer on '$owner' — retrying across all nodes." 'WARN'
                        $null  = Invoke-NcSsh -Name $sshTarget -Command (& $nodeshell 'rm' '*') -Credential $NcCredential -ErrorAction Stop
                        $after = & $readOut (Invoke-NcSsh -Name $sshTarget -Command (& $nodeshell 'ls' '*') -Credential $NcCredential -ErrorAction Stop)
                    }

                    # Only the node that owns the volume can answer 'No such file or directory',
                    # so that string is positive proof the file is gone. Absence of the name is
                    # NOT proof — the path is echoed back inside every error line, so a reply that
                    # never reached the volume would otherwise read as a clean success.
                    if ($after -match 'No such file or directory') {
                        Write-DFSLog "  Removed leftover symlink file '/vol/$rel' (verified gone on '$owner')." 'OK'
                    }
                    elseif ($after -match 'Volume is not known') {
                        Write-DFSLog ("  Ran rm for '/vol/$rel' but COULD NOT VERIFY — no node reported owning volume " +
                                      "'$containerVol'. Check by hand: run -node * -command `"priv set diag; ls /vol/$rel`"") 'WARN'
                    }
                    else {
                        Write-DFSLog ("  Symlink file '/vol/$rel' is STILL PRESENT after rm — needs manual cleanup. " +
                                      "Nodeshell said: $($after -replace '\s+', ' ')") 'WARN'
                    }
                }
                catch {
                    Write-DFSLog "  Could not remove symlink file '/vol/$rel' — needs manual cleanup: $($_.Exception.Message)" 'WARN'
                }
            }
        }
    }

    if ($shareIsShared) {
        Write-DFSLog 'Phase 2 REFUSED: the share is targeted by another live DFS link, so the storage is still in use.' 'ERROR'
        return
    }

    if (-not $IncludeBackingStorage) {
        Write-DFSLog "Phase 2 skipped (no -DeleteBackingStorage). Data is still on disk." 'WARN'
        return
    }

    # ---- Phase 2: backing storage (irreversible) ----
    Write-DFSLog "PHASE 2 — backing storage for '$($Row.DfsPath)' (method: $($Row.DeleteMethod))" 'STEP'

    $method = $Row.DeleteMethod
    $targetName = switch ($method) {
        'Qtree'     { $Row.Qtree }
        'Directory' { "$($Row.Volume)/$($Row.DeleteRelPath)" }
        default     { $Row.Volume }
    }

    if ($method -eq 'Volume' -and $Cfg.Protected -contains $Row.Volume) {
        Write-DFSLog "  REFUSED: volume '$($Row.Volume)' is in ProtectedVolumes — it is shared infrastructure and will not be deleted." 'ERROR'
        return
    }

    # Belt-and-braces: never let a subfolder share reach the qtree primitive. Removing the
    # qtree would take every sibling folder with it.
    if ($method -eq 'Qtree' -and -not [string]::IsNullOrWhiteSpace($Row.SubPathSuffix)) {
        Write-DFSLog "  REFUSED: target has a sub-path ('$($Row.SubPathSuffix)') but was classified as a qtree. Refusing rather than risk deleting siblings." 'ERROR'
        return
    }

    # The old type-the-name prompt lived here. It has been replaced by Confirm-DFSDeletion at the
    # call site, which is strictly stronger: it runs BEFORE phase 1 rather than only guarding the
    # data, it requires the full DFS path plus an arithmetic answer, and -Force cannot skip it.
    # This one could be skipped with -Force, which meant the only typed confirmation in the script
    # disappeared behind a flag whose documented purpose was suppressing an FSA warning.
    if (-not $ChallengePassed -and -not $NoPrompt) {
        $expected = if ($method -eq 'Directory') { Split-Path -Leaf $Row.DeleteRelPath } else { $targetName }
        $typed = Read-Host "Type '$expected' exactly to confirm irreversible deletion of '$targetName'"
        if ($typed -ne $expected) {
            Write-DFSLog '  Confirmation did not match — Phase 2 aborted.' 'WARN'
            return
        }
    }

    switch ($method) {

        'Qtree' {
            if ($PSCmdlet.ShouldProcess("Qtree '$targetName' on volume '$($Row.Volume)'", 'Remove (irreversible)')) {
                $q = Get-NcQtree -Volume $Row.Volume -VserverContext $svm -ErrorAction SilentlyContinue |
                     Where-Object { $_.Qtree -eq $targetName }
                if ($q) {
                    $q | Remove-NcQtree -Force -Confirm:$false
                    Write-DFSLog "  Removed qtree '$targetName'." 'OK'
                }
                else {
                    Write-DFSLog "  Qtree '$targetName' not found — nothing removed." 'WARN'
                }
            }
        }

        'Directory' {
            # A Windows-created folder inside a qtree/volume. The only correct primitive is a
            # recursive directory delete scoped to exactly this path and its contents.
            if ([string]::IsNullOrWhiteSpace($Row.DeleteRelPath)) {
                Write-DFSLog '  REFUSED: directory delete requested but DeleteRelPath is empty (that would target the volume root).' 'ERROR'
                return
            }
            $vol = Get-NaVolume -Context $RestContext -VolumeName $Row.Volume -Vserver $svm
            if (-not $vol) {
                Write-DFSLog "  Volume '$($Row.Volume)' could not be resolved for the directory delete." 'ERROR'
                return
            }
            try {
                $outcome = Remove-NaDirectory -Context $RestContext -VolumeUuid $vol.Uuid -Path $Row.DeleteRelPath
                if ($outcome) {
                    Write-DFSLog "  Recursively removed '/$($Row.DeleteRelPath)' in volume '$($Row.Volume)'." 'OK'
                }
            }
            catch {
                Write-DFSLog "  Failed to remove directory '/$($Row.DeleteRelPath)' in '$($Row.Volume)': $($_.Exception.Message)" 'ERROR'
            }
        }

        default {
            if ($PSCmdlet.ShouldProcess("Volume '$targetName'", 'Offline, dismount and remove (irreversible)')) {
                try {
                    Get-NcVol -Name $targetName -VserverContext $svm | Set-NcVol -Offline -Confirm:$false
                    Start-Sleep -Seconds 5
                    Get-NcVol -Name $targetName -VserverContext $svm | Dismount-NcVol -Force -Confirm:$false
                    Start-Sleep -Seconds 5
                    Get-NcVol -Name $targetName -VserverContext $svm | Remove-NcVol -Force -Confirm:$false -ErrorAction Stop
                    Write-DFSLog "  Removed volume '$targetName'." 'OK'
                }
                catch {
                    Write-DFSLog "  Failed to remove volume '$targetName' — manual cleanup needed: $($_.Exception.Message)" 'ERROR'
                }
            }
        }
    }
}

# =======================================================================================
# Main
# =======================================================================================

$cfg = Get-DFSCleanupConfig -MainConfigPath $ConfigPath -CleanupConfigPath $DFSCleanupConfigPath

foreach ($d in @($cfg.ExportRoot, $cfg.LogRoot)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
$script:LogFile = Join-Path $cfg.LogRoot "dfs-cleanup-$Mode-$RunStamp.log"

Write-DFSLog "Mode=$Mode  Cluster=$($cfg.ClusterAlias)  SVM=$($cfg.Vserver)  Thresholds=$($cfg.CandidateYears)y/$($cfg.ImmediateYears)y" 'STEP'
Write-DFSLog "Log: $script:LogFile"

Import-DFSModules -Cfg $cfg

# --- ONTAP toolkit connection (cmdlets) ---
Write-DFSLog "Connecting to cluster '$($cfg.ClusterAlias)'..."
$null = Connect-NcController $cfg.ClusterAlias -ErrorAction Stop
Write-DFSLog "Connected to '$($cfg.ClusterAlias)'." 'OK'

# --- CyberArk credential (REST/analytics, and SSH for the symlink cleanup) ---
$restContext = $null
$ncCredential = $null
# Resolve needs REST too: the symlink-file index is discovered through the files endpoint, and
# without it the container volume holding each symlink file is unknown.
if ($Mode -in @('Preflight', 'Resolve', 'Analyze', 'Report', 'Delete')) {
    $ca = $cfg.Clean.CyberArk
    Write-DFSLog "Resolving REST credential (source=$CredentialSource, CCP '$($ca.CCPAddress)')..."

    $resolved = Resolve-NaCredential -RestHost $cfg.RestHost -ClusterAlias $cfg.ClusterAlias `
                    -Source $CredentialSource `
                    -CCPAddress $ca.CCPAddress -CyberArkAppId $ca.AppId -CyberArkUsername $ca.UserName `
                    -IsWriteOperation:($Mode -eq 'Delete') `
                    -AllowFallbackForWrite:$AllowFallbackForWrite `
                    -SkipCertificateCheck:$SkipCertificateCheck

    foreach ($a in $resolved.Attempts) {
        $lvl = if ($a.Result -like 'OK*') { 'OK' } elseif ($a.Result -like 'FAILED*') { 'WARN' } else { 'INFO' }
        Write-DFSLog "  [$($a.Source)] $($a.Result)" $lvl
    }

    $ncCredential = $resolved.Credential
    $securePw = $resolved.SecurePassword
    $restContext = Get-NaRestContext -RestHost $cfg.RestHost -Username $resolved.UserName `
                                     -Password $securePw -SkipCertificateCheck:$SkipCertificateCheck

    if ($resolved.IdentitySwapped) {
        # Say it loudly: the cluster audit log will attribute this run to a different account
        # than the CyberArk service account the runbook names.
        Write-DFSLog ("Using LOCALLY CACHED credential '$($resolved.UserName)' instead of the CyberArk " +
                      "account — cluster audit entries for this run will name '$($resolved.UserName)'.") 'WARN'
    }
    else {
        Write-DFSLog "Credential retrieved for '$($resolved.UserName)' from $($resolved.Source)." 'OK'
    }
}

$results = [System.Collections.Generic.List[object]]::new()

switch ($Mode) {

    'Preflight' {
        # Enumerate what actually exists on the SVM. The protected-volume list is a deletion
        # guard, not an inventory — probing it by name warns about volumes on other clusters.
        $vols = @(Get-NaVolumeList -Context $restContext -Vserver $cfg.Vserver)
        Write-DFSLog "Found $($vols.Count) volume(s) on SVM '$($cfg.Vserver)'." 'STEP'

        foreach ($info in $vols) {
            $needs = ($info.AnalyticsState -ne 'on') -or ($info.AccessTimeEnabled -eq $false)
            # Only a finished scan yields usable age data — this is the flag Analyze/Report key on.
            $ready = ($info.AnalyticsState -eq 'on') -and
                     ($null -eq $info.AnalyticsInitState -or $info.AnalyticsInitState -in @('complete', 'successful'))
            $results.Add([PSCustomObject]@{
                Volume             = $info.Name
                Uuid               = $info.Uuid
                State              = $info.State
                AnalyticsSupported = $info.AnalyticsSupported
                AnalyticsState     = $info.AnalyticsState
                InitState          = $info.AnalyticsInitState
                ScanProgress       = $info.ScanProgress
                FilesScanned       = $info.FilesScanned
                TotalFiles         = $info.TotalFiles
                AccessTimeEnabled  = $info.AccessTimeEnabled
                UsedGB             = $(if ($info.UsedBytes) { [math]::Round($info.UsedBytes / 1GB, 2) } else { $null })
                Protected          = ($cfg.Protected -contains $info.Name)
                AnalyticsReady     = $ready
                NeedsAction        = $needs
            })
        }

        # Scope the enable to the volumes asked for, so a broad -Force cannot start scans on
        # volumes nobody approved.
        if ($Volume) {
            $unknown = @($Volume | Where-Object { $_ -notin @($results.Volume) })
            if ($unknown) { Write-DFSLog "Not found on '$($cfg.Vserver)': $($unknown -join ', ')" 'WARN' }
            Write-DFSLog "Scoped to volume(s): $($Volume -join ', ')" 'STEP'
        }

        $results | Sort-Object @{E = 'NeedsAction'; D = $true }, Volume |
            Format-Table Volume, AnalyticsState, InitState, ScanProgress, AccessTimeEnabled, UsedGB, AnalyticsReady, NeedsAction -AutoSize

        $csvOut = Join-Path $cfg.ExportRoot "dfs-cleanup-preflight-$RunStamp.csv"
        $results | Export-Csv -LiteralPath $csvOut -NoTypeInformation -Encoding utf8
        Write-DFSLog "Wrote preflight state to '$csvOut'." 'OK'

        # ONTAP runs a limited number of FSA initialization scans at once, and starting more
        # while one is running just queues them. Surface that instead of firing blind.
        $initializing = @($results | Where-Object { $_.AnalyticsState -eq 'initializing' -or $_.InitState -eq 'running' })
        if ($initializing) {
            Write-DFSLog "Already initializing: $(($initializing.Volume) -join ', '). Let these finish before enabling more — analytics data on them is incomplete until then." 'WARN'
        }

        $todo = @($results | Where-Object { $_.NeedsAction -and $_.AnalyticsState -notin @('initializing') })
        if ($Volume) { $todo = @($todo | Where-Object { $_.Volume -in $Volume }) }
        if (-not $EnableAnalytics) {
            if ($todo) {
                $totalGb = ($todo | Measure-Object -Property UsedGB -Sum).Sum
                Write-DFSLog "$($todo.Count) volume(s) need FSA enabled ($([math]::Round($totalGb/1024,2)) TB to scan): $(($todo.Volume) -join ', ')" 'WARN'
                Write-DFSLog "Re-run with -EnableAnalytics to turn them on. Each starts a full initialization scan." 'WARN'
            }
            else {
                Write-DFSLog 'All volumes have FSA on and access-time enabled.' 'OK'
            }
        }
        else {
            if ($initializing -and -not $Force) {
                Write-DFSLog "Refusing to start new scans while $(($initializing.Volume) -join ', ') is still initializing. Re-run with -Force to override." 'ERROR'
            }
            else {
                foreach ($info in $todo) {
                    Enable-NaVolumeAnalytics -Context $restContext -VolumeUuid $info.Uuid -VolumeName $info.Volume `
                        -EnableAccessTime:($info.AccessTimeEnabled -eq $false) -Confirm:(-not $Force) | Out-Null
                }
            }
        }
    }

    default {
        # @() at the call site: a single path would otherwise come back as a bare string, and
        # String has no .Count under StrictMode.
        # -ForceDeletePath targets do not have to appear in the workbook or a CSV — the whole point
        # is that someone named a path the age rule was never going to reach. They are folded into
        # the explicit list so a run consisting ONLY of them does not trip "No DFS paths to work on".
        $forceSet = @{}
        foreach ($fp in @($ForceDeletePath)) {
            if ([string]::IsNullOrWhiteSpace($fp)) { continue }
            $forceSet[$fp.Trim().TrimEnd('\').ToLowerInvariant()] = $true
        }
        if ($forceSet.Count -gt 0 -and $Mode -ne 'Delete') {
            throw '-ForceDeletePath is only valid with -Mode Delete.'
        }

        $explicit = @($Path) + @($ForceDeletePath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $paths = @(Get-TargetPaths -Cfg $cfg -Explicit $explicit -Csv $InputCsv -Excel:$FromExcel)

        if ($forceSet.Count -gt 0) {
            Write-DFSLog ("$($forceSet.Count) path(s) supplied via -ForceDeletePath: deleting on a person's " +
                          'authority, NOT on age evidence. Each one still requires the interactive challenge.') 'WARN'
        }

        $verdictMap = @{}
        if ($Mode -eq 'Delete') {
            # Only evidence-based targets need the verdict CSV. A run that is purely
            # -ForceDeletePath has no verdicts to look up, and demanding a Report first would just
            # push people back towards -Force.
            $needsEvidence = @($paths | Where-Object { -not $forceSet.ContainsKey($_.Trim().TrimEnd('\').ToLowerInvariant()) })
            if ($needsEvidence.Count -gt 0) {
                if (-not $VerdictFile) {
                    throw ("-Mode Delete requires -VerdictFile (a CSV from -Mode Report) for the " +
                           "$($needsEvidence.Count) target(s) not named by -ForceDeletePath. " +
                           'Deleting without stored evidence is not supported.')
                }
            }
            if ($VerdictFile) {
                if (-not (Test-Path -LiteralPath $VerdictFile)) { throw "VerdictFile '$VerdictFile' not found." }
                foreach ($r in (Import-Csv -LiteralPath $VerdictFile)) {
                    if ($r.PSObject.Properties.Name -contains 'DfsPath' -and $r.DfsPath) {
                        $verdictMap[$r.DfsPath.Trim().ToLowerInvariant()] = $r
                    }
                }
                Write-DFSLog "Loaded $($verdictMap.Count) stored verdict(s) from '$VerdictFile'."
            }
        }

        # Loaded once, before any target is touched, so a bad manifest fails the run up front
        # instead of on whichever path happens to come first.
        $overrideMap = $null
        if ($Mode -eq 'Delete' -and $OverrideManifest) {
            $overrideMap = Import-DFSOverrideManifest -Path $OverrideManifest
            if (-not $overrideMap) {
                throw ("Override manifest '$OverrideManifest' was rejected — see the errors above. " +
                       "Fix it or drop -OverrideManifest to confirm each path interactively.")
            }
        }
        elseif ($Mode -eq 'Delete' -and $Force) {
            # Said plainly, because -Force used to be enough and someone will try it again.
            Write-DFSLog ('-Force does NOT authorise deletion on its own. Each path will still be ' +
                          'confirmed interactively; use -OverrideManifest for unattended runs.') 'WARN'
        }

        $i = 0
        foreach ($p in $paths) {
            $i++
            Write-DFSLog "[$i/$($paths.Count)] $p" 'STEP'

            $row = Resolve-DFSTarget -Cfg $cfg -DfsPath $p -RestContext $restContext
            if (-not $row.Resolved) {
                Write-DFSLog "  Unresolved: $($row.Note)" 'WARN'
            }
            else {
                Write-DFSLog "  $($row.TargetType): share=$($row.Share) vol=$($row.Volume) qtree=$($row.Qtree) link=$($row.Link)"
            }

            if ($Mode -in @('Analyze', 'Report')) {
                $row = Add-DFSAnalysis -Cfg $cfg -Context $restContext -Row $row -WithPerFileProof:$PerFileProof
                $bound = if ($row.AgeIsLowerBound) { ' (lower bound)' } else { '' }
                # "idle=y" with no number was just a null YearsIdle printed into the string.
                $idle = if ($null -ne $row.YearsIdle -and $row.YearsIdle -ne '') { "$($row.YearsIdle)y" } else { 'n/a' }
                Write-DFSLog "  Verdict: $($row.Verdict)  idle=$idle$bound" $(if ($row.Verdict -in @('IMMEDIATE','EMPTY')) { 'OK' } else { 'INFO' })
            }

            if ($Mode -eq 'Delete') {
                $isForced = $forceSet.ContainsKey(([string]$p).Trim().TrimEnd('\').ToLowerInvariant())

                # -ForceDeletePath sets aside the AGE EVIDENCE only. Everything that protects
                # against deleting the wrong object still runs: the protected-volume list, the
                # sub-path-classified-as-qtree refusal, and the multi-widelink share preservation
                # are all inside Remove-DFSTarget and are not reachable from here.
                $check = if ($isForced) {
                    Write-DFSLog ("  -ForceDeletePath: skipping the verdict/Approved requirement for " +
                                  "'$p'. Safety refusals still apply.") 'WARN'
                    [PSCustomObject]@{ Allowed = $true; Reason = 'Authorised by a person via -ForceDeletePath (no age evidence required)' }
                }
                else {
                    Test-DeletionAllowed -Cfg $cfg -Row $row -Approved $ApprovedVerdicts -VerdictMap $verdictMap
                }

                # Delete mode gathers no evidence of its own. Carry the verdict that was actually
                # approved onto the row, so the confirmation screen and the run's output CSV say
                # what this deletion was justified by instead of leaving the field absent.
                $stored = if (-not $isForced -and $check.Allowed) { $check['Stored'] } else { $null }
                $row | Add-Member -NotePropertyName 'Verdict' -NotePropertyValue $(
                    if     ($isForced) { 'FORCED (a person''s authority, no age evidence)' }
                    elseif ($stored)   { $stored.Verdict }
                    else               { 'n/a (not analysed this run)' }) -Force
                $row | Add-Member -NotePropertyName 'ContentMeasured' -NotePropertyValue $(
                    if ($stored -and ($stored.PSObject.Properties.Name -contains 'ContentMeasured')) {
                        $stored.ContentMeasured
                    } else { 'not measured this run' }) -Force

                if (-not $check.Allowed) {
                    Write-DFSLog "  REFUSED: $($check.Reason)" 'ERROR'
                    $row | Add-Member -NotePropertyName 'DeleteOutcome' -NotePropertyValue "Refused: $($check.Reason)" -Force
                }
                else {
                    Write-DFSLog "  Allowed: $($check.Reason)"

                    # Spreadsheet approval says this target is PERMITTED. The challenge asks
                    # whether the operator, right now, means to do it. Two different questions —
                    # the first can be weeks old and written by someone else.
                    if (-not $WhatIfPreference -and -not (Confirm-DFSDeletion -Row $row `
                            -IncludeBackingStorage:$DeleteBackingStorage -Override $overrideMap `
                            -ManagerAuthorised:$isForced)) {
                        $row | Add-Member -NotePropertyName 'DeleteOutcome' -NotePropertyValue 'Refused: operator confirmation failed' -Force
                    }
                    else {
                        Remove-DFSTarget -Cfg $cfg -Row $row -RestContext $restContext -NcCredential $ncCredential `
                                         -IncludeBackingStorage:$DeleteBackingStorage -NoPrompt:$Force -ChallengePassed
                        $outcome = if ($isForced) {
                            $who = if ($row.PSObject.Properties.Name -contains 'AuthorisedBy') { $row.AuthorisedBy } else { 'unrecorded' }
                            "Processed (ForceDeletePath, authorised by: $who)"
                        }
                        else { 'Processed' }
                        $row | Add-Member -NotePropertyName 'DeleteOutcome' -NotePropertyValue $outcome -Force
                    }
                }
            }

            $results.Add($row)
        }

        # --- Output ---
        $csvOut = Join-Path $cfg.ExportRoot "dfs-cleanup-$($Mode.ToLower())-$RunStamp.csv"
        $results | Export-Csv -LiteralPath $csvOut -NoTypeInformation -Encoding utf8
        Write-DFSLog "Wrote $($results.Count) row(s) to '$csvOut'." 'OK'

        if ($Mode -eq 'Report') {
            $xlsxSource = $cfg.Clean.Excel.SourcePath
            if (Test-Path -LiteralPath $xlsxSource) {
                # The tracker sheet is updated IN PLACE. It used to gain a 'DFS_Cleanup_<stamp>'
                # sheet per run, which meant a path someone added in column A was analysed but its
                # own row stayed blank forever, and the file grew a worksheet a day. The tracker
                # is what people read, so the tracker is what gets written.
                #
                # Not gated on ShouldProcess: this is now the normal output of a Report run, the
                # file is backed up immediately below, and prompting breaks the scheduled task
                # (the script declares ConfirmImpact='High' for the deletion work, so every
                # ShouldProcess call prompts). -WhatIf is still honoured.
                $backup = $null
                if (-not $WhatIfPreference) {
                    # '.bak-<stamp>' on purpose: that is the pattern the scheduled task's pruning
                    # step already matches, so these backups get aged out instead of piling up.
                    $backup = Join-Path (Split-Path -Parent $xlsxSource) (
                        [System.IO.Path]::GetFileNameWithoutExtension($xlsxSource) +
                        ".bak-$RunStamp.xlsx")
                    Copy-Item -LiteralPath $xlsxSource -Destination $backup -Force
                    Write-DFSLog "Backed up tracker to '$backup' before updating." 'OK'
                }

                $headerRow = 0
                if ($cfg.Clean.Excel.PSObject.Properties.Name -contains 'HeaderRow') {
                    $headerRow = [int]$cfg.Clean.Excel.HeaderRow
                }

                $upd = Update-DFSWorkbookInPlace -Path $xlsxSource `
                            -WorksheetName $cfg.Clean.Excel.WorksheetName `
                            -KeyColumn $cfg.Clean.Excel.PathColumn `
                            -Results @($results) -HeaderRow $headerRow -Confirm:$false

                # Symlink_Map and Anomalies are pure output — rebuilt wholesale, because that is
                # the only way a symlink REMOVED from the cluster ever leaves the map.
                $sheets = Get-DFSSymlinkMapAndAnomalies -Cfg $cfg -Context $restContext
                if ($sheets) {
                    $null = Set-DFSWorkbookSheet -Path $xlsxSource -WorksheetName 'Symlink_Map' `
                                -Rows $sheets.Map -Confirm:$false
                    $null = Set-DFSWorkbookSheet -Path $xlsxSource -WorksheetName 'Anomalies' `
                                -Rows $sheets.Anomalies -Confirm:$false
                }

                if ($upd -and $upd.CellsWritten -gt 0 -and -not $WhatIfPreference) {
                    # Put it where the four people who read it can see it. The local file stays
                    # authoritative if the share write fails.
                    if ($cfg.Clean.Excel.SharePath -and $cfg.Clean.Excel.PublishToShare) {
                        Publish-DFSWorkbookToShare -LocalPath $xlsxSource -SharePath $cfg.Clean.Excel.SharePath -Confirm:$false
                    }
                }
            }
            else {
                Write-DFSLog "Excel SourcePath '$xlsxSource' not found — CSV only." 'WARN'
            }
        }

        if ($Mode -in @('Analyze', 'Report')) {
            Write-Host ''
            $results | Group-Object Verdict | Sort-Object Name |
                Format-Table @{L = 'Verdict'; E = { $_.Name } }, @{L = 'Count'; E = { $_.Count } } -AutoSize
        }
    }
}

Write-DFSLog "Done ($Mode)." 'OK'
