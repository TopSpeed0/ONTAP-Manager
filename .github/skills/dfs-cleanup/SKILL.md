---
name: dfs-cleanup
description: 'Assess and decommission cold DFS-backed CIFS shares, qtrees and volumes on ONTAP using File System Analytics age evidence. Use when: delete DFS share, decommission share, remove qtree, DFS cleanup, volumes or qtree to delete, last access age, File System Analytics, FSA, access_time_enabled, volume analytics, stale share, unused share, cold data, 3 year rule, 7 year rule, Invoke-DFSDecommission, delete-shareNsym, remove widelink, remove symlink, reclaim space.'
argument-hint: 'Specify the mode (Preflight, Resolve, Analyze, Report, Delete) and the DFS UNC path(s) or -FromExcel'
---

# DFS Cleanup & Decommission

## When to Use
- Deciding whether a DFS share / qtree is cold enough to delete
- Reporting last-access and last-modified age per qtree or volume from File System Analytics
- Resolving a list of DFS UNC paths to their underlying share / volume / qtree / widelink
- Checking whether FSA and access-time tracking are even enabled before trusting age data
- Actually removing a share, widelink, symlink file and backing qtree/volume

For read-only *path resolution* only, `dfs-management` is the lighter skill. This one adds age
evidence and deletion.

## Key Concepts

### The rule this implements
Thresholds live in `Config_DFSCleanup.json`, never in code:
- No new files **and** no access in `CandidateYears` (3) → `CANDIDATE`, needs approval
- Same over `ImmediateYears` (7) → `IMMEDIATE`, eligible for deletion

Both dimensions must agree; the verdict uses whichever of accessed/modified time is *more
recent*, since read-cold but write-warm is not idle.

### FSA collapses its oldest bucket — this matters
File System Analytics returns per-directory byte histograms. The recent end is fine-grained
(`2026 - WEEK 29`, `2025-Q1`); the old end collapses into one bucket (`2022 or OLDER`, `--2Y`).

That proves a 3-year rule but **cannot** prove a 7-year rule — "2022 or older" could be 2021 or
2009. When the newest non-empty bucket is the collapsed one, the age is a **lower bound**
(`AgeIsLowerBound = True`).

With `RequirePerFileProofForImmediate: true` (default), an `IMMEDIATE` verdict additionally
requires real per-file `accessed_time`/`modified_time` timestamps (`-PerFileProof`). Without
proof the verdict is held down to `CANDIDATE`. An incomplete walk (`Complete = $false`) never
counts as proof.

### Reconciliation order matters
Per-file timestamps are read **before** the verdict is formed, not after:

| Situation | Result |
|---|---|
| Proof **newer** than histogram | Proof wins — verdict backs off |
| Proof **older**, histogram age was a **lower bound** | Proof wins — refines the collapsed bucket. This is the only path to `IMMEDIATE` |
| Proof **older**, histogram age was **exact** | Histogram wins — a bounded walk must not argue past exact data |

Consulting proof only after the histogram reaches `IMMEDIATE` makes `IMMEDIATE` unreachable: a
collapsed bucket caps the measurable age near the collapse boundary (~3.5y), never clearing 7y.

### `access_time_enabled` is a separate switch
A volume can have `analytics.state = on` while access-time tracking is off, which makes
`by_accessed_time` meaningless. Both are checked; if atime is off the verdict falls back to
modify time only and immediate deletion is withheld.

### Target shapes and the correct delete primitive
`TargetType` × `DeleteMethod`:

| TargetType | Layout | `DeleteMethod` |
|---|---|---|
| `QtreeWidelink` / `QtreeDirectShare` | share → real qtree | `Qtree` |
| `VolumeWidelink` / `VolumeDirectShare` | share → whole volume | `Volume` |
| `SubfolderWidelink` / `SubfolderDirectShare` | share → **plain folder** inside a qtree/volume | `Directory` |

A direct hidden share resolves with no `LINK`, so there is no widelink to clean up.

### ⚠️ Subfolder shares: never delete these as a qtree
A DFS link can point at a share whose path is *below* the qtree — a Windows-created folder such
as `/datavol1/App_Q/SomeFolder`. `Get-DFSNameSpaceRoot` still reports `QTREE = App_Q` for it,
because it takes the qtree from the path's second component.

Calling `Remove-NcQtree App_Q` there deletes **every sibling folder in that qtree**. So
classification checks depth *before* type:

- 1 level (`/vol`) → `Volume`
- exactly 2 levels **and** component 2 is a real qtree (verified via `Get-NcQtree`, never
  assumed) → `Qtree`
- deeper, or 2 levels where component 2 is not a qtree → `Directory`

`Directory` uses `DELETE /storage/volumes/{uuid}/files/{path}?recurse=true`, scoped to that path
and its contents. Guards: an empty relative path is refused (would target the volume root), and
a target with a `SubPathSuffix` can never reach the qtree primitive.

Deep UNC paths: `Get-DFSNameSpaceRoot` errors past `\\server\dfsshare\link\one-more-level`, so
longer paths resolve at the link level and the remainder is carried as `SubPathSuffix`.

### The tracker's Status column is not authoritative
Rows marked `DELETED` have turned out to still hold data. `Resolve` probes the cluster and that
result wins over anything the spreadsheet claims.

### Orphan fallback — widelink-first resolution hides live data
`Get-DFSNameSpaceRoot` resolves via the widelink, so once the widelink is gone it reports
"widelink not found" even when the share, qtree and data remain. Phase-1-only cleanups leave
exactly that state.

On failure, `Resolve` looks up `<name>$` / `<name>` as a CIFS share, then `<name>_Q` / `<name>`
as a qtree anywhere on the SVM (indexed once per run):

| `OrphanState` | Meaning |
|---|---|
| `Live` | Resolved through the widelink |
| `OrphanShare` | No widelink, share still exists |
| `OrphanQtree` | No widelink or share, qtree still exists |
| `FullyGone` | Not found by any route — genuinely deleted |

`ResolvedVia` = `Widelink` / `ShareByName` / `QtreeByName` / `None`.

First production run found four `DELETED` rows with live storage, one at 1.5 TiB whose share
pointed at `/<vol>/<name>_Q` that was a **plain directory, not a qtree** — while a sibling row
with an identically-shaped `_Q` path *was* a real qtree. Never infer a qtree from the name.

### Only assess volumes whose scan has finished
`Preflight` reports `ScanProgress` and `AnalyticsReady`. `Analyze`/`Report` return
`NO_ANALYTICS` for any volume where `initialization.state` is not complete, so a running scan
cannot produce a verdict. Wait for the scan rather than reading a partial histogram.

## Configuration

Two files together:
- `config.json` — clusters, `DFS_Config.<alias>` (Vserver/CifsAlias/DfsShare/DfsPath),
  `Personal_modules` (must list `Get-DFSNameSpaceRoot.psm1`)
- `Config_DFSCleanup.json` — CyberArk CCP, `AgeThresholds`, `ProtectedVolumes`, Excel settings

Template: `Config_DFSCleanup.template.json`.

Credentials: `Connect-NcController` for the NetApp.ONTAP cmdlets, CyberArk CCP for the REST
analytics calls. Nothing is written to disk.

## Existing Script

`scripts/dfs-cleanup/Invoke-DFSDecommission.ps1` — see
`scripts/dfs-cleanup/README.md` for full detail.

| Module | Role |
|---|---|
| `Get-DFSCleanupAnalytics.psm1` | FSA queries, histogram label parsing, per-file walk, verdict |
| `Get-NaApiCred.psm1` | CyberArk CCP fetch, plus `Resolve-NaCredential` — CCP first, local toolkit cache as a read-only fallback |
| `Test-NaCyberArkAuth.ps1` | Diagnose a CCP failure — turns `APPEX003E` into the actual cause. Read-only, retrieves no secret |
| `Get-DFSNameSpaceRoot.psm1` | Path resolver. **Workspace copy** — a run loads nothing from outside `Netapp-Code-WorkSpace` |
| `Find-NcSymlinkFile.ps1` | Locate a symlink FILE by name or target across every volume |
| `Script-4-Human.ps1` | **Gitignored** copy-paste cheat sheet for every mode. Cannot be executed (`#Requires -Version 99.0` plus a `throw`) — copy one block out of it |

### Workbook: local master + published copy

`Excel.SourcePath` is a local master in `scripts/dfs-cleanup/DFS_CleanUP/`; `Excel.SharePath` is the
copy the manager reads and adds rows to. Every run pulls a newer *and different* share copy down
first (SHA256 compared, local backed up), then publishes the result back (share backed up). Local
work is never silently discarded, and `null` SharePath means local-only.

No symlink is used: the workspace is inside OneDrive, where reparse points become cloud
placeholders (tag `0x9000601a`), and creating one to a UNC path is blocked by endpoint security.

The header row is **searched for**, not assumed — the plain tracker has headers on row 1, the
published one on row 4 under a title block.

### Verdicts
`IMMEDIATE` · `CANDIDATE` · `ACTIVE` · `EMPTY` · `NO_ANALYTICS` · `NO_ATIME` · `REVIEW`

## Procedures

### Check whether analytics data is trustworthy
```powershell
Set-Location <workspace-root>; . .\profile1.ps1
.\scripts\dfs-cleanup\Invoke-DFSDecommission.ps1 -Mode Preflight
```
Reports `analytics.state`, `initialization.state` and `access_time_enabled` per volume.
Add `-EnableAnalytics` to turn on what is missing — this starts a full initialization scan and
is the only non-read-only preflight action.

### Resolve a path list (read-only)
```powershell
.\scripts\dfs-cleanup\Invoke-DFSDecommission.ps1 -Mode Resolve -FromExcel
.\scripts\dfs-cleanup\Invoke-DFSDecommission.ps1 -Mode Resolve -Path '\\<alias>\dfs\<link>'
```
Also probes whether share / qtree / volume still exist, so tracker rows already actioned show
up as gone rather than being re-processed.

### Assess and report
```powershell
.\scripts\dfs-cleanup\Invoke-DFSDecommission.ps1 -Mode Report -FromExcel -PerFileProof
```
Writes a CSV to `scripts/dfs-cleanup/exports/` **and updates the `CAB1` worksheet in place**,
cell by cell. It does not add a per-run worksheet — that behaviour was removed, because a path
someone added in column A was analysed while its own row stayed blank forever, and the file grew a
worksheet a day.

Anyone can add a UNC path to **column A**; the next Report run fills the rest of that row in. The
tracker is copied to `*.bak-<stamp>.xlsx` before every write.

`CAB1` is written with `Open-ExcelPackage`, never `Export-Excel` — the latter replaces a worksheet
wholesale and would destroy the title block, the styling, and the `Actual Path` formula on every
row. `Comments`, `commands`, `Is Backuped` and `Actual Path` are **never written**; a `$null` value
leaves the cell alone rather than blanking it. `Size (GB)`, `Status`, `Last Accessed` and
`Last Modified` **are** re-verified every run — the hand-maintained size had gone stale by orders of
magnitude. A mapped column missing from the sheet is **appended**, not skipped.

`Last Accessed` / `Last Modified` show an exact date with `-PerFileProof`, otherwise an FSA
**period** (`2025 (FSA period)`). `Last Accessed` appends `- may include this scan` when access looks
current but modify is over a year older — see the directory-atime trap below.

**History is protected once a target is gone:** `Size (GB)`, `Last Accessed`, `Last Modified` and
`Content (measured)` are left exactly as they were, because after a deletion those figures are the
only record of what was removed. Only `Status` changes, to `GONE`. Do not "tidy" this by writing
`n/a` over them — that was the original behaviour and it destroyed the evidence. There is no ledger
file by design: the stale row is the record.

Note `GONE` cannot currently distinguish "deleted by someone else" from "deleted by this script" —
our own deletions are recorded only in the run CSV and log, not in the workbook. Known and
deliberately not built.

### Two traps in the age evidence

**An empty directory is not zero bytes.** FSA reports the directory inode (4096 / 20480 bytes
observed) with `FileCount 0` and `SubdirCount 0`. `EMPTY` is keyed on the counts, never on
`BytesUsed` — the bytes test never fired and empty qtrees fell through to the histogram.

**Reading a directory updates its own `accessed_time`, and FSA counts that inode.** So after a scan
every target carries a current-week access bucket the size of its inode, and since a verdict takes
the most-recently-touched of access/modify, that can force `ACTIVE` on data that is years old.
The per-file walk is clean (it skips directory records); the contamination is at the directory
level, which is exactly what the histogram sees. `$ObservationStart` exists to discard those buckets
and is **deliberately unused** pending an explicit maintainer decision - discarding evidence makes targets look
older and more deletable, so it is a policy call, not a code fix. Do not enable it unilaterally.

**A REST 404 on the target path means GONE, not NO_ANALYTICS.** `Get-NaDirectoryAnalytics` returns
`PathMissing` and the verdict is `GONE`, checked ahead of the scan-state guards. The two readings
are opposite instructions: one says wait, the other says the row is finished.

`Symlink_Map` and `Anomalies` are the opposite: pure output, nobody hand-edits them, so they are
**rebuilt wholesale every run** via `Set-DFSWorkbookSheet` (`Export-Excel -ClearSheet`). Cell
matching would never remove a symlink that no longer exists on the cluster. Both row sets come from
`Resolve-NaSymlinkChain` and `Get-DFSAnomaly` in the analytics module — pure functions over
already-fetched tables, unit-tested offline. `Find-NcSymlinkFile.ps1` calls the same resolver, so
the script and the worksheet cannot disagree.

Three things not to undo: `-ClearSheet` (without it a shorter run leaves stale rows behind); the
empty-result guard (no rows almost always means the scan failed, so the sheet is kept, not
emptied); and the tab-order restore (`-ClearSheet` recreates the sheet at the end of the workbook,
and people navigate this file by tab). The container scan is cached in `$script:SymlinkContainers`
— it is the slowest step in a run, so never let it happen twice.

### Delete
```powershell
# Always dry-run first
.\scripts\dfs-cleanup\Invoke-DFSDecommission.ps1 -Mode Delete -Path '<path>' `
    -VerdictFile <exports\dfs-cleanup-report-*.csv> -WhatIf

# Phase 1 only — share + links, data still recoverable
.\scripts\dfs-cleanup\Invoke-DFSDecommission.ps1 -Mode Delete -Path '<path>' -VerdictFile <csv>

# Phase 2 as well — irreversible
.\scripts\dfs-cleanup\Invoke-DFSDecommission.ps1 -Mode Delete -Path '<path>' `
    -VerdictFile <csv> -DeleteBackingStorage

# On a person's authority, where no age evidence exists or ever will
.\scripts\dfs-cleanup\Invoke-DFSDecommission.ps1 -Mode Delete -ForceDeletePath '<unc>'

# Unattended, no console — the only way
.\scripts\dfs-cleanup\Invoke-DFSDecommission.ps1 -Mode Delete -FromExcel `
    -VerdictFile <csv> -OverrideManifest <json>
```

## Safety Rules

1. `-Mode Delete` **requires** `-VerdictFile` from a prior `Report` for every evidence-based
   target. No stored evidence, no deletion — `-Force` does not bypass this.
2. **Human approval is mandatory.** `Report` writes `MarkedForDeletion` but leaves `Approved`
   blank. Deletion acts only on rows where a person set `Approved` to `YES`. A blank value, or a
   report with no `Approved` column, is refused — `-Force` does not bypass this either.
3. Only `IMMEDIATE` and `EMPTY` are deletable by default. Promoting `CANDIDATE` needs an
   explicit `-ApprovedVerdicts`.
4. Phase 1 (share/widelink/symlink) and Phase 2 (backing storage) are separate. Phase 2 needs
   `-DeleteBackingStorage`.
5. Volumes in `ProtectedVolumes` are never deleted as a whole, even when empty. Qtrees and
   folders inside them still can be.
6. A subfolder share is never deleted via the qtree primitive — see the warning above.
7. **Per-target interactive challenge, before anything is removed:** type `YES` → answer a
   randomly generated multiplication → type the **full DFS path**. One wrong answer refuses that
   target and the run continues; there are no retries. Passing it suppresses the downstream
   `[Y] [A] Yes to All [N]` prompts for that target (`$ConfirmPreference = 'None'`, function-scoped)
   so there is one deliberate decision instead of six numb ones. `ShouldProcess` is still called,
   so `-WhatIf` propagates through every destructive call.
8. **Neither `-Force` nor `-Confirm:$false` authorises deletion.** `-Force` previously set
   `-NoPrompt`, which killed the only typed confirmation — and that one guarded Phase 2 only, so
   Phase 1 had nothing but `[Y/A/N]`. That was a reachable silent bulk delete of every approved
   row. Closed. A **non-interactive session refuses outright** (`UserInteractive` *and*
   `IsInputRedirected` are both checked — under `pwsh -File` with redirected stdin, `Read-Host`
   returns empty instantly).

### The only two ways past the interactive step

- **`-OverrideManifest <json>`** — unattended runs. Top-level `Override` exactly `OVERRIDE`
  (case-sensitive), `Date` = **today**, `Operator` = the Windows identity actually running, and
  every path listed individually with its own `OVERRIDE` value. No wildcard, no `ALL`. A rejected
  manifest **aborts the run**; an unlisted path falls through to the interactive gate. Dating it
  today is what stops one manifest authorising deletions forever.
- **`-ForceDeletePath '<unc>'`** — deletion on a person's authority (manager, dev team, legal)
  where the age rule can never produce evidence. Skips the verdict + `Approved` requirement and
  **nothing else**. Adds a **fourth** challenge asking who authorised it, recorded in the log and
  as `Processed (ForceDeletePath, authorised by: ...)`. A force-only run needs no `-VerdictFile`;
  a mixed run still does, for the non-forced targets. A manifest deliberately **cannot** authorise
  a `-ForceDeletePath` target — that would stack two bypasses, leaving a deletion with no evidence
  *and* nobody present.

Do not weaken any of the above without approval from a designated maintainer. `scripts/testing/Test-DFSCleanupScripts.ps1`
(**92 offline checks**, no cluster or credentials) guards most of it — run it after any edit.

## Key Implementation Notes

### Sort field must match the question
The superseded `ONTAP\shares\Get-NetAppFiles.psm1` queried `order_by=size desc&max_records=1000`
and the caller then sorted by `accessed_time`. On a directory with more than 1000 files that
yields the newest of the 1000 *largest* files — the genuinely newest file can be absent, so any
age decision from it is wrong. Query sorted by the field being measured.

### Histogram labels and values must come from the same object
`GET /storage/volumes/{uuid}/files/{path}` returns the contents of `{path}` as `records`, and
the analytics of `{path}` itself in the response's top-level `analytics`. The old
`Get-NetAppQtreeAnalytics.psm1` took labels from the response root and values from a child
record; that works only because ONTAP repeats identical labels in both. Read both from one
object.

### The files endpoint is not recursive
One call lists one directory. `Get-NaNewestTimestamp` queues subdirectories itself, under a
depth and directory budget, and reports `Complete = $false` when a budget is hit.

### `order_by=accessed_time desc` is not universally supported
Some ONTAP releases reject it. The walk falls back to an unsorted read and takes the maximum
client-side — same answer, more records read.

### Unrecognised bucket labels are surfaced, not assumed
`ConvertFrom-NaTimeLabel` handles week / quarter / month / year / collapsed / unknown forms.
Anything else returns `Kind = 'Unparsed'` and is listed in the verdict reasons rather than
being quietly treated as old.
