# DFS Cleanup / Decommission

Decide whether a DFS-backed share is cold enough to delete — then delete it safely.

Replaces four loose variants of `ONTAP\shares\delete-shareNsym*.ps1` and the three helper
modules that sat beside them.

## Files

| File | Purpose |
|------|---------|
| `Invoke-DFSDecommission.ps1` | Entry point. `-Mode Preflight\|Resolve\|Analyze\|Report\|Delete` |
| `Get-DFSCleanupAnalytics.psm1` | File System Analytics (FSA) queries, histogram parsing, verdict logic |
| `Get-NaApiCred.psm1` | CyberArk CCP credential fetch (nothing stored on disk), plus `Resolve-NaCredential` — CCP first, local toolkit cache as a read-only fallback |
| `Test-NaCyberArkAuth.ps1` | Diagnose a CCP failure. Turns `APPEX003E` into the actual cause; read-only, retrieves no secret |
| `Get-DFSNameSpaceRoot.psm1` | DFS path resolver. Workspace copy — see below |
| `Find-NcSymlinkFile.ps1` | Locate a symlink FILE by name or target, across every volume |
| `DFS_CleanUP/` | Local workbook master + backups (gitignored) |
| `exports/` | CSV + Excel output (gitignored) |
| `logs/` | Per-run logs (gitignored) |

### Self-contained

A run loads **nothing from outside this workspace**. `Get-DFSNameSpaceRoot.psm1` used to be
referenced in place from the `Widelink - DFS` folder via `config.json` → `Personal_modules`; it now
lives here and that entry is only a fallback. Re-copy it if the original changes.

The workspace copy carries one fix: it defines `DisplayInBytes`, which the original calls for quota
formatting but never defines — it inherited the helper from `Na-Module-reports.psm1` when run inside
the Jenkins reports. Standalone the call threw, the caller swallowed the whole widelink resolution
as "failed", and the target was then reported as an **orphaned share**. Only qtrees *with a quota*
reach that path, which is why it hid for so long.

The only deliberate cross-project dependency is `Test-NaCyberArkAuth.ps1`, which optionally uses the
`workspace-mobaxterm` module to read a log on the CCP host. It degrades gracefully without it.

## Setup

```powershell
Copy-Item Config_DFSCleanup.template.json Config_DFSCleanup.json
# then edit: ClusterAlias, RestHost, CyberArk, Excel.SourcePath, Excel.SharePath
```

`config.json` must contain a `DFS_Config.<ClusterAlias>` block.

Requires PowerShell 7+, `NetApp.ONTAP`, and `ImportExcel` (Excel modes only).

## The workbook: local master, published copy

The tracker exists twice on purpose.

| | Path | Role |
|---|---|---|
| **Local master** | `Excel.SourcePath` → `DFS_CleanUP/` | What the tool reads and writes. Authoritative for a run |
| **Published copy** | `Excel.SharePath` | What the manager sees, and where they add new shares to investigate |

Each run does **pull → work → publish**:

1. **Pull** (`SyncFromShare`) — if the share copy is *different* **and** *newer*, it replaces the
   local master, so rows the manager added are included. Comparison is SHA256 first, so a file
   that was merely touched changes nothing. The local copy is backed up as
   `*.local-<stamp>.xlsx` before being replaced. If **local** is newer it is kept and a warning
   is logged — the tool never silently discards local work.
2. **Publish** (`PublishToShare`) — the finished workbook is copied to the share, after backing
   the existing share copy up as `*.bak-<stamp>.xlsx`. If the manager has it open in Excel the
   copy fails, and the message says so: the result is still complete locally.

Set `Excel.SharePath` to `null` to work purely locally.

> **No symlink.** The obvious design — a link from the workspace to the share — is not available
> here. The workspace sits inside a OneDrive-synced tree, where a reparse point is converted into
> a cloud placeholder (`fsutil reparsepoint query` shows tag `0x9000601a`), and creating a symlink
> to a UNC path is blocked outright by endpoint security (`New-Item -ItemType SymbolicLink` →
> `Access is denied`). Copying is the mechanism that actually works.

### Header row is detected, not assumed

The plain tracker has its headers on row 1; the published workbook has a title block above them
(row 4). `Import-ExcelSafely` locates the header by searching the first 25 rows for
`Excel.PathColumn`. Assuming row 1 produced the worst kind of failure — a run that reported
`Read 39 rows` and then aborted with `No DFS paths to work on`, which points at the input list
rather than at the header. Override with `Excel.HeaderRow` if ever needed.

## Credentials

FSA is REST-only — `Get-Command -Module NetApp.ONTAP *Analytic*` returns nothing — so a ZAPI
session from `Connect-NcController` cannot answer age questions. REST needs its own credential.

`-CredentialSource Auto` (default) tries CyberArk CCP first and falls back to the ONTAP toolkit's
local credential cache only if the CCP is unreachable:

```
[CyberArk] FAILED — 400   →   [ToolkitCache] OK — 'admin'      (CCP outage)
[CyberArk] OK — retrieved 'SvcAccount'                          (normal)
```

CCP is always preferred: it is rotated and audited. The fallback exists so a CCP outage cannot
block read-only assessment. For `-Mode Delete` the fallback is **refused** unless you pass
`-AllowFallbackForWrite`, because it changes the identity recorded in the cluster's audit log.
`-CredentialSource CyberArk` disables the fallback entirely; `Cache` skips the CCP.

Candidates from the cache are proved against `/api/cluster` before being used. That check matters:
ONTAP authorises per `application`, so an account holding only `ontapi` + `ssh` is rejected by REST
with a bare **401 that is indistinguishable from a wrong password**. Cache entries are keyed by
whatever host string was passed to `Connect-NcController`, so one cluster can hold several entries
naming *different* accounts — keying the lookup on the REST hostname can hand you the one account
that cannot do the job.

When a CCP fetch fails, run `Test-NaCyberArkAuth.ps1` rather than guessing. `APPEX003E` is returned
for essentially every authentication failure and names no cause; the two real ones it decodes are a
stale reverse-DNS record and an OS User entry that cannot work over CCP.

## Confirmation behaviour

The script declares `ConfirmImpact = 'High'` for the deletion work, so **every** `ShouldProcess`
call prompts. Only genuinely destructive steps are gated on it:

| Step | Gated? |
|---|---|
| CSV output | no |
| Tracker update in place | no — backed up first, `-WhatIf` still respected |
| Publish to the share | no prompt, `-WhatIf` respected |
| Enabling FSA, deleting share / widelink / symlink / qtree / volume | **yes** |

Gating the workbook write killed `-Mode Report` in any non-interactive session with
`PowerShell is in NonInteractive mode. Read and Prompt functionality is not available.` — worth
remembering before adding a `ShouldProcess` to a path the scheduled task runs.

## How the tracker gets filled in

The workbook is the deliverable, not a by-product. Anyone who wants a path investigated adds the
UNC to **column A** of the `CAB1` sheet; the next `-Mode Report` run fills the rest of that row in.

`Report` updates `CAB1` **in place**, cell by cell, via `Update-DFSWorkbookInPlace`. It does not
add a worksheet. Earlier versions exported a `DFS_Cleanup_<stamp>` sheet per run, which meant a
row someone added in column A was analysed but its own row stayed blank forever, and the file grew
a worksheet a day.

Written with `Open-ExcelPackage`, not `Export-Excel`: `Export-Excel` replaces a worksheet
wholesale, which would destroy the title block, the column widths, the fills, and the
`Actual Path` formula that sits on every row.

Column ownership is enforced in code, not by convention:

| Class | Columns | Behaviour |
|---|---|---|
| Key | `DFS to Delete` | matched on, never written |
| Human | `Comments`, `commands`, `Is Backuped`, `Actual Path` | **never written** — hand-written judgement outranks anything computed |
| Tool | the other 24, incl. `Size (GB)`, `Status`, `Last Accessed`, `Last Modified` | re-verified against the cluster every run |

A tool column that is **missing from the sheet is appended**, not skipped — new headers go on the
end so existing column positions are undisturbed. Skipping it silently meant nobody could tell
whether the data was missing or the column was.

**`Last Accessed` / `Last Modified`** carry either an exact date (with `-PerFileProof`, from real
per-file timestamps) or an FSA **period** label such as `2025 (FSA period)` — a bucket is a period,
never dressed up as a date. `Last Accessed` appends **`- may include this scan`** when access looks
current while modify is over a year older, because of the directory-atime trap described below.

**History is protected once a target is gone.** `Size (GB)`, `Last Accessed`, `Last Modified` and
`Content (measured)` are then **left exactly as they were** — after a deletion those figures are the
only record of what was removed. Only `Status` changes, to `GONE`, and `AutoNotes` states that the
four columns hold the last measured values. There is deliberately no separate ledger file: the stale
row is the record.

`Size (GB)` used to be hand-maintained and is now measured, because it had gone badly stale: 2.47
GiB recorded against a qtree that measures zero, and 1.55 TiB against three paths that do not
exist. A figure nobody re-checks is worse than no figure. It reports `n/a - gone`, `0 (empty)`, or a
scaled `MiB`/`GiB`/`TiB`. The hand-entered values survive in the `.bak-<stamp>.xlsx` backups and in
`Volumes or Qtree to Delete - ORIGINAL.xlsx`.

### Two traps in the age evidence — read before trusting a verdict

**An empty directory is not zero bytes.** FSA reports the directory **inode** — 4096 bytes for one
verified-empty qtree, 20480 for another, both with `FileCount 0` and `SubdirCount 0`. So `EMPTY` is
keyed on the file and subdirectory counts, never on `BytesUsed`. Testing bytes meant the branch
never fired and the row fell through to the histogram.

**Reading a directory updates the directory's own `accessed_time`, and FSA counts that inode in the
histogram.** This is self-inflicted contamination: after a scan, every measured target carries an
access bucket for the current week whose size is exactly its inode. Because a verdict takes the
most-recently-touched of access and modify, that bucket can force `ACTIVE` on a target whose real
data is years old — one qtree holds 9.9 GB in the `2022 or OLDER` bucket, modify time 2025, and
still verdicts `ACTIVE`.

The narrower claim — that the **per-file** walk does not stamp file atimes — is true;
`Get-NaNewestTimestamp` skips directory records before collecting any timestamp. The contamination
is at the directory level, which is what the histogram sees.

`$ObservationStart` on `Get-DFSCleanupVerdict` exists to fix this by discarding access buckets whose
window opened after the run began. **It is currently unused, and that is a deliberate open
decision, not an oversight** — discarding evidence makes targets look older and therefore more
deletable, so the rule is the owner's call, not the tool's.

Three rules that matter more than they look:

- A tool column whose value is `$null` this run is **left alone, not blanked**. A failed cluster
  read must not erase yesterday's good answer.
- Formula cells are skipped whatever column they are in.
- Keys are matched on a trimmed, lower-cased path. The tracker has carried trailing spaces
  (`...\Inst `); matching raw strings finds no row and loses the findings with no error at all.
- A path that was analysed but has no row in the sheet is **logged as a warning**, never dropped
  silently.

The tracker is copied to `*.bak-<stamp>.xlsx` before every write. That name is deliberate — it is
the pattern the scheduled task's pruning step already matches, so the backups age out.

`Content (measured)` is a **direct** measurement, deliberately not FSA. FSA answers "how much does
this hold" from a scan that may be hours old or still initializing; the tracker's question is "is
there anything in here right now". Six rows carried a recorded size that direct measurement
contradicted — `Utils` recorded 2.47 GiB and measured empty — which is why the column exists. The
probe is first-page-only (`Get-NaDirectoryEntries -FirstPageOnly`): proving non-empty needs one
entry, and paging to the end of a 1.2M-file directory costs hundreds of round trips to answer a
yes/no question.

### The three worksheets, and why two are written differently

| Sheet | Written how | Why |
|---|---|---|
| `CAB1` | **cell by cell**, human columns protected | people type in it — hand-written judgement must survive |
| `Symlink_Map` | **rebuilt wholesale** each run | pure output. Cell-matching would never remove a symlink that no longer exists on the cluster |
| `Anomalies` | **rebuilt wholesale** each run | same |
| `Legend` | never touched | static reference |

`Symlink_Map` and `Anomalies` used to be built by a one-off pass outside this script, so they froze
the moment it finished while the workbook claimed to refresh daily. Both are now produced on every
run by `Resolve-NaSymlinkChain` and `Get-DFSAnomaly` (both in the analytics module, both pure
functions over already-fetched tables, so both are unit-tested offline).

Three details that matter:

- **`-ClearSheet`** is what makes the rebuild a replace rather than an append. Without it a run
  with fewer rows than the last leaves the previous run's surplus behind — reporting symlinks that
  are gone.
- **An empty result never wipes a sheet.** No rows almost always means the scan failed, not that
  every symlink was deleted, so the existing sheet is kept and a warning is logged.
- **The tab order is restored** afterwards. `-ClearSheet` drops and recreates the worksheet, which
  lands it at the end; left alone, every run would shuffle the tabs people navigate by.

The container scan behind all this is the slowest step in a run (~80s), so it is cached and reused
rather than repeated. `Find-NcSymlinkFile.ps1` calls the same `Resolve-NaSymlinkChain`, so the
script and the worksheet can never disagree about what a symlink points at.

Anomaly severities, highest first: **`DO NOT DELETE`** (removing the named object destroys data
beyond the intended target) · **`Care`** (it can go, but only if every route to it goes too) ·
**`Review`** (unreachable or inconsistent, needs a human) · **`Note`** (true and worth knowing,
not a hazard).

`Status` is the tracker's own vocabulary and is **not** `Verdict`. `Verdict` answers "how old is
it"; `Status` answers "what state is this object in". `GONE` is a fact about the cluster;
`CANDIDATE` is an opinion about age. Keeping them separate is intentional.

## Deleting: two independent gates

`Approved=YES` in the spreadsheet and the operator confirmation are **different questions**. The
first can be weeks old and written by someone else; the second asks whether you, right now, mean
to do this. Both must pass.

### Gate 1 — stored evidence

`-Mode Delete` requires `-VerdictFile` (a CSV from a Report run) and refuses any row whose
`Approved` cell is empty. No evidence, no deletion.

### Gate 2 — the operator, per target

Before anything is removed, `Confirm-DFSDeletion` asks three things that cannot be answered from
muscle memory:

1. Type `YES`.
2. Answer a randomly generated multiplication — the numbers change every call, so the answer
   cannot be pre-loaded.
3. Type the **full DFS path** being deleted.

One wrong answer refuses that target and the run moves to the next path. There are no retries: a
second attempt at the same sum is the autopilot the gate exists to defeat.

Once it passes, the per-object `[Y] [A] Yes to All [N]` prompts underneath are suppressed for that
target (`$ConfirmPreference = 'None'`, scoped to the function). Six numb prompts after one real
decision is exactly how `[A] Yes to All` gets pressed. `ShouldProcess` is still *called*, so
`-WhatIf` keeps working.

**`-Force` does not bypass this, and neither does `-Confirm:$false`.** It used to: `-Force` set
`-NoPrompt`, which skipped the only typed confirmation in the script — and that prompt guarded
only Phase 2. Combined with `[A] Yes to All`, or with `-Confirm:$false`, that was a silent bulk
delete of every approved row. That is closed.

A **non-interactive session refuses outright**. There is no console to challenge, so the answer is
no. `Test-DFSInteractiveConsole` checks both `UserInteractive` (false under a scheduled task) and
`IsInputRedirected` (true under `... | pwsh -File`, where `Read-Host` returns empty immediately
rather than waiting for a person).

### Unattended deletion — the override manifest

The only way to delete without a console. `-OverrideManifest <path.json>`:

```json
{
  "Override": "OVERRIDE",
  "Date":     "<today, yyyy-MM-dd>",
  "Operator": "<DOMAIN>\\<your-account>",
  "Paths": {
    "\\\\<ns>\\dfs\\<Link>\\<Sub>": "OVERRIDE",
    "\\\\<ns>\\dfs\\<OtherLink>":   "OVERRIDE"
  }
}
```

Four checks, **all** required:

| Check | Rule | Why |
|---|---|---|
| `Override` | exactly `OVERRIDE`, case-sensitive | a typo must not authorise anything |
| `Date` | **today's** local date | stops a manifest being written once and left in place authorising deletions forever; yesterday's file is worthless by design |
| `Operator` | must match the Windows identity actually running | a manifest authored by someone else does not authorise your run, and yours does not authorise theirs |
| `Paths` | each path carries its **own** `OVERRIDE` value | no wildcard, no `ALL` keyword. A path absent from the manifest is not authorised even if every other path in the run is — it falls through to the interactive challenge |

A rejected manifest **aborts the run** rather than quietly falling back. A path the manifest does
not name falls through to the interactive gate, which then refuses if there is no console.

The accepted manifest is logged with the resolved operator, date and path count, so the run log
records who authorised what.

### Deleting on a person's authority — `-ForceDeletePath`

For the case the age rule cannot cover: a manager, the dev team or legal says a path is no longer
needed. There is no 3-year evidence and there never will be, but someone is accountable.

```powershell
.\Invoke-DFSDecommission.ps1 -Mode Delete -ForceDeletePath '\\<ns>\dfs\<Link>\<Sub>'
```

Then, interactively: `YES` → the arithmetic → the full path → **who authorised it**.

The fourth step exists because the age rule is normally the justification and it writes itself into
the verdict CSV. When a person overrules it, the justification *is* that person's name — if it
isn't captured, the run log records a deletion nobody can account for six months later. It is free
text (name, or a ticket number) and lands in the row outcome as
`Processed (ForceDeletePath, authorised by: ...)`.

| Property | Behaviour |
|---|---|
| Needs to be in the workbook? | **No** — that is the point |
| `-VerdictFile` required? | Only for targets *not* named by `-ForceDeletePath`. A force-only run needs none |
| Skips `Approved=YES` / verdict check? | **Yes** — this is the one thing it skips |
| Skips the interactive challenge? | **No.** Four steps, always |
| Can the override manifest authorise it? | **No.** That would stack two bypasses and leave a deletion with no evidence and nobody present. One bypass at a time |
| Skips the protected-volume list? | **No** |
| Skips the sub-path-classified-as-qtree refusal? | **No** |
| Skips multi-widelink share preservation? | **No** |
| Valid outside `-Mode Delete`? | No — throws |

## The deletion rule

Set in `Config_DFSCleanup.json`, not in code:

| Threshold | Meaning |
|---|---|
| `CandidateYears` (3) | No new files **and** no access in 3 years → `CANDIDATE`, needs approval |
| `ImmediateYears` (7) | Same test over 7 years → `IMMEDIATE`, eligible for deletion |

Both dimensions must agree. A directory that is read-cold but write-warm is not idle, so the
verdict uses whichever of accessed/modified time is *more recent*.

### Why 7 years needs a second source

FSA reports per-directory byte histograms whose oldest bucket is collapsed — `2022 or OLDER`,
`--2Y`. That is enough to clear a 3-year bar but it cannot establish 7 years, because
"2022 or older" could equally mean 2021 or 2009.

So when the newest non-empty bucket is the collapsed one, the reported age is a **lower bound**
(`AgeIsLowerBound = True`). With `RequirePerFileProofForImmediate: true` (the default), an
`IMMEDIATE` verdict additionally requires real per-file `accessed_time`/`modified_time` values —
run with `-PerFileProof`. Without that proof the verdict is held down to `CANDIDATE` rather than
being granted on histogram evidence alone.

The per-file walk is recursive and **bounded**. If it hits its depth or directory budget it
returns `Complete = $false`, and an incomplete walk never counts as proof.

### How the two sources are reconciled

Per-file timestamps are read *before* any verdict is formed, then reconciled with the histogram:

| Situation | Result |
|---|---|
| Proof shows activity **newer** than the histogram | Proof wins — verdict backs off. Newer evidence always beats older. |
| Proof shows activity **older**, histogram age was a **lower bound** | Proof wins — it legitimately refines a collapsed bucket upward. This is the path to `IMMEDIATE`. |
| Proof shows activity **older**, histogram age was **exact** | Histogram wins — a bounded walk should not argue past exact data. |

Getting this order wrong makes `IMMEDIATE` unreachable: a collapsed bucket caps the measurable
histogram age just past the collapse boundary (~3.5y), which never clears a 7-year bar, so proof
has to be consulted before the verdict rather than after it.

### Verdicts

| Verdict | Meaning |
|---|---|
| `IMMEDIATE` | Past `ImmediateYears`, proof collected — eligible for deletion |
| `CANDIDATE` | Past `CandidateYears` — needs a human decision |
| `ACTIVE` | Touched inside `CandidateYears` — leave alone |
| `EMPTY` | No bytes, no files — **measured**, see below |
| `NO_ANALYTICS` | FSA off, unsupported, or still initializing — no decision possible |
| `NO_ATIME` | `access_time_enabled` is false, so access data can't be trusted |
| `REVIEW` | Evidence incomplete or contradictory — look by hand |

### EMPTY: what it proves, and what it does not

`EMPTY` is deletable by default (`-ApprovedVerdicts` is `IMMEDIATE, EMPTY`), so it carries the most
weight of any verdict. It is only ever issued on **positive** evidence:

- FSA must report `bytes_used = 0` **and** `file_count = 0`.
- Missing, null or `incomplete_data` results return `NO_ANALYTICS`, never `EMPTY`. Treating absent
  data as "nothing here" once turned a failed analytics read into "safe to delete everything";
  two tests now pin that down.
- Emptiness can also be established without FSA, by counting directory entries — which is how
  targets were decided while FSA initialization was still running.

> **Not re-verified at deletion time.** `-Mode Delete` acts on the verdict stored in the CSV and
> does not re-measure. A target that was empty when the report ran can have data written into it
> before the deletion runs. The `Approved=YES` column gates it, but a ticked box is not a fresh
> measurement. Until a re-check is added: **re-run `-Mode Report` immediately before deleting**, and
> treat a verdict file older than a day as stale.

## Usage

```powershell
Set-Location <workspace-root>; . .\profile1.ps1

# 1. Is the analytics data trustworthy yet?
.\scripts\dfs-cleanup\Invoke-DFSDecommission.ps1 -Mode Preflight

# 1b. Turn FSA on where it is missing (starts a full initialization scan)
.\scripts\dfs-cleanup\Invoke-DFSDecommission.ps1 -Mode Preflight -EnableAnalytics

# 2. Map every path in the tracker to share / volume / qtree / widelink
.\scripts\dfs-cleanup\Invoke-DFSDecommission.ps1 -Mode Resolve -FromExcel

# 3. Full assessment + CSV + updated workbook copy
.\scripts\dfs-cleanup\Invoke-DFSDecommission.ps1 -Mode Report -FromExcel -PerFileProof

# 4. Dry run the deletion
.\scripts\dfs-cleanup\Invoke-DFSDecommission.ps1 -Mode Delete -Path '\\<alias>\dfs\<link>' `
    -VerdictFile .\scripts\dfs-cleanup\exports\dfs-cleanup-report-<stamp>.csv -WhatIf

# 5. For real, including backing storage
.\scripts\dfs-cleanup\Invoke-DFSDecommission.ps1 -Mode Delete -Path '\\<alias>\dfs\<link>' `
    -VerdictFile .\scripts\dfs-cleanup\exports\dfs-cleanup-report-<stamp>.csv -DeleteBackingStorage
```

`Preflight`, `Resolve`, `Analyze` and `Report` are read-only (`Preflight -EnableAnalytics` is
the one exception).

## Safety model

Five independent gates on destructive work:

1. **Stored verdict required.** `-Mode Delete` demands a `-VerdictFile` from a prior `Report`
   run. A target with no recorded evidence is refused, `-Force` included.
2. **Approved verdicts only.** Defaults to `IMMEDIATE` and `EMPTY`. `CANDIDATE` is not
   deletable by default — promoting it is a human decision via `-ApprovedVerdicts`.
3. **Two phases.** Phase 1 removes the share, widelink and leftover symlink file; the data
   survives. Phase 2 touches backing storage and only runs with `-DeleteBackingStorage`.
4. **Protected volumes.** Volumes in `ProtectedVolumes` are never deleted as a whole, even
   when empty. Qtrees inside them still can be.
5. **Typed confirmation + `ShouldProcess`.** Phase 2 asks you to type the target name unless
   `-Force`. `-WhatIf` propagates through every destructive call.

## Orphan detection — why "DELETED" in a tracker means nothing

`Get-DFSNameSpaceRoot` resolves **widelink-first**. Once the widelink is removed it reports
"widelink not found" even when the share, the qtree and all the data are still there. A
Phase-1-only cleanup produces exactly that state, so a spreadsheet row saying `DELETED` can still
have terabytes behind it.

When widelink resolution fails, `Resolve` falls back to looking the objects up by name: a CIFS
share called `<name>$` or `<name>`, then a qtree called `<name>_Q` or `<name>` anywhere on the
SVM (indexed once per run). Two columns record the outcome:

| `OrphanState` | Meaning |
|---|---|
| `Live` | Resolved normally through the widelink |
| `OrphanShare` | No widelink, but the CIFS share still exists |
| `OrphanQtree` | No widelink and no share, but the qtree still exists |
| `FullyGone` | Nothing found by widelink, share name or qtree name — genuinely deleted |

`ResolvedVia` records which route found it (`Widelink` / `ShareByName` / `QtreeByName` / `None`).

This is not hypothetical. On the first production run, four rows marked `DELETED` still had
storage — including one at 1.5 TiB whose share pointed at `/<vol>/<name>_Q` where `<name>_Q`
turned out to be a **plain directory, not a qtree**. Only the existence check distinguished it
from a sibling row whose identically-named `_Q` path *was* a real qtree.

## Approval workflow

Deletion needs **two** independent gates. The verdict says a target *looks* deletable; the
`Approved` column says a person *decided* it is. `-Force` bypasses neither — it only skips the
typed-name prompt.

1. `-Mode Report` writes `MarkedForDeletion` (the machine's proposal) and leaves `Approved`,
   `ApprovedBy`, `ApprovedDate` **blank**.
2. A human reviews and sets `Approved` to `YES` on the signed-off rows.
3. `-Mode Delete` acts only on rows where the verdict is in `-ApprovedVerdicts` **and**
   `Approved` reads yes/y/true/1/approved.

A blank `Approved`, or a report with no `Approved` column at all, is refused.

## Target shapes

`TargetType` and `DeleteMethod` record what the path actually resolved to, because the correct
delete primitive differs — and picking the wrong one destroys data:

| TargetType | Layout | `DeleteMethod` | Phase 1 removes |
|---|---|---|---|
| `QtreeWidelink` | DFS link → share → qtree on a shared volume | `Qtree` | share, widelink, symlink file |
| `VolumeWidelink` | DFS link → share → whole volume | `Volume` | share, widelink, symlink file |
| `SubfolderWidelink` | DFS link → share → **plain folder** inside a qtree/volume | `Directory` | share, widelink, symlink file |
| `QtreeDirectShare` | `\\<alias>\<share>$` → qtree, no DFS link | `Qtree` | share only |
| `VolumeDirectShare` | `\\<alias>\<share>$` → whole volume, no DFS link | `Volume` | share only |
| `SubfolderDirectShare` | `\\<alias>\<share>$` → plain folder, no DFS link | `Directory` | share only |

### Why subfolder shares need their own primitive

A DFS link can point at a share whose path sits *below* the qtree — a folder someone created
from Windows, e.g. `/datavol1/App_Q/SomeFolder`. `Get-DFSNameSpaceRoot` still reports
`QTREE = App_Q` for that share, because it reads the qtree from the path's second component.

Acting on that naively means calling `Remove-NcQtree App_Q` — which deletes **every sibling
folder in that qtree**, not just the target. So classification checks *depth first*:

- share path is 1 level (`/vol`) → `Volume`
- share path is exactly 2 levels **and** the second component is a real qtree
  (verified with `Get-NcQtree`, not assumed) → `Qtree`
- anything deeper, or 2 levels where the component is *not* a qtree → `Directory`

`Directory` deletes recursively via `DELETE /storage/volumes/{uuid}/files/{path}?recurse=true`,
scoped to exactly that path and its contents. Two extra guards: an empty relative path is
refused (it would target the volume root), and a target carrying a sub-path can never reach the
qtree primitive.

Deep UNC paths are handled too. `Get-DFSNameSpaceRoot` errors past
`\\server\dfsshare\link\one-more-level`, so anything longer is resolved at the link level and
the remainder is carried as `SubPathSuffix` and appended to `DeleteRelPath`.

## Known ONTAP behaviour

- **`access_time_enabled` is separate from `analytics.state`.** FSA can be `on` while access
  time tracking is off, in which case `by_accessed_time` is not meaningful. Both are checked.
- **The files endpoint is not recursive.** `GET /storage/volumes/{uuid}/files/{path}` lists one
  directory. The per-file walk queues subdirectories itself.
- **`order_by=accessed_time desc` is not accepted by every ONTAP release.** The walk falls back
  to an unsorted read and takes the maximum client-side.
- **Sort field must match the question.** The superseded `Get-NetAppFiles.psm1` queried
  `order_by=size desc&max_records=1000` and then sorted by `accessed_time`, which on a
  directory of more than 1000 files returns the newest of the 1000 *largest* files — the
  genuinely newest file can be missing entirely. Age decisions from that are wrong.
