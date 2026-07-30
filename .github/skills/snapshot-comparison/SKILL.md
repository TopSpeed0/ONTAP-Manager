---
name: snapshot-comparison
description: 'Read-only snapshot inventory and comparison across all configured ONTAP clusters. Use when: comparing snapshots across clusters, finding the oldest snapshots, finding the largest snapshots, snapshot space reclamation candidates, snapshot age report, snapshot size report, which snapshots are old, which snapshots are big, snapshot sprawl, locked or busy snapshots. Never deletes anything.'
argument-hint: 'Optionally name a cluster, an age threshold in days, and a size threshold in GiB'
---

# Snapshot Comparison

## When to Use
- Comparing snapshots across every configured cluster in one table
- Finding the oldest snapshots (age ranking) or the largest snapshots (size ranking)
- Listing the snapshots that cross a configurable age / size threshold, as reclamation **candidates** for a human to review
- Checking which snapshots are locked (busy, or owned by a clone / dump / SnapMirror)

## Read-only guarantee

The only ONTAP command this workflow ever issues is `vol snapshot show`. It never deletes,
creates, modifies, renames or restores a snapshot, and it never touches
`snapshot autodelete`. The command is built by `Get-SnapshotInventoryCommand`, which
throws if a mutating verb ever appears in the string it produced. Both source files are
scanned for mutating command strings by the offline test suite.

Actual deletion stays a separate, deliberate, human decision. This tool only tells you
what is there.

## Files

| Path | Role |
|---|---|
| `scripts/snapshots/Get-SnapshotComparison.ps1` | Driver — cluster selection, collection, reports |
| `scripts/snapshots/Get-SnapshotInventory.psm1` | Pure parsing / ranking functions (no cluster access) |
| `scripts/testing/Test-SnapshotComparisonScripts.ps1` | Offline test suite (no cluster required) |
| `scripts/testing/fixtures/snapshots/*.txt` | Sanitised captures of real `vol snapshot show` output |
| `scripts/Start-ScriptManager.ps1` | Registers both under `Snapshots` / `Testing` (alias `sm`) |

`scripts/snapshots/Get-BiggestSnapshot.ps1` is a separate, older script and stays as it is —
it answers "biggest snapshots on a cluster". Use this workflow when age, thresholds,
per-cluster comparison or offline replay matter.

## Usage

```powershell
Set-Location <workspace-root>; . .\profile1.ps1

# Every cluster in config.json, defaults: age >= 90 d, size >= 100 GiB
.\scripts\snapshots\Get-SnapshotComparison.ps1

# One cluster, by Alias or cluster name, with tighter thresholds
.\scripts\snapshots\Get-SnapshotComparison.ps1 -Cluster <alias> -AgeDays 30 -LargeThresholdGB 50

# Only VIP-marked clusters, deeper rankings
.\scripts\snapshots\Get-SnapshotComparison.ps1 -VIP -TopOldest 200 -TopLargest 200

# Narrow to one SVM or volume (filtered ONTAP-side, not after collection)
.\scripts\snapshots\Get-SnapshotComparison.ps1 -Cluster <alias> -Svm <svm> -Volume <vol>

# Capture once, then re-threshold offline as often as you like — no cluster contact
.\scripts\snapshots\Get-SnapshotComparison.ps1 -VIP -SaveRaw
.\scripts\snapshots\Get-SnapshotComparison.ps1 -ReplayFrom .\scripts\snapshots\reports\<stamp> -AgeDays 365
```

### Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `-Cluster <name>` | all | One cluster by `Alias` or `cluster` (via `Get-OntapTargetClusters`) |
| `-VIP` | off | Only VIP-marked clusters |
| `-AgeDays <n>` | 90 | A snapshot at or over this age is an **old candidate** |
| `-LargeThresholdGB <n>` | 100 | A snapshot at or over this size (GiB) is a **large candidate** |
| `-TopOldest <n>` | 50 | Rows in the oldest ranking |
| `-TopLargest <n>` | 50 | Rows in the largest ranking |
| `-Svm` / `-Volume` | — | ONTAP-side `-vserver` / `-volume` filter |
| `-OutputPath <dir>` | `scripts\snapshots\reports\<stamp>` | Report directory |
| `-SaveRaw` | off | Also keep each cluster's untouched SSH output under `raw\` |
| `-ReplayFrom <dir>` | — | Rebuild reports from a previous `-SaveRaw` capture; contacts no cluster |
| `-ConfigRoot <dir>` | repo root | Where `config.json` lives — set this when running from a git worktree |

## Output

Written to `-OutputPath`. Every CSV carries cluster, SVM, volume, snapshot, creation time,
calculated age in days, size in bytes and human units, SnapMirror label, state, busy, owners
and a `Locked` flag.

| File | Contents |
|---|---|
| `snapshots-all.csv` | Every snapshot collected |
| `snapshots-oldest.csv` | Top-N by age, `Rank` 1 = oldest |
| `snapshots-largest.csv` | Top-N by size, `Rank` 1 = largest |
| `snapshots-old-candidates.csv` | Everything at or over `-AgeDays` |
| `snapshots-large-candidates.csv` | Everything at or over `-LargeThresholdGB` |
| `snapshots-unknown.csv` | Snapshots whose size or creation time could not be read |
| `cluster-summary.csv` | Per-cluster counts, total size, oldest, largest, candidate counts |
| `problems.csv` | SSH and parse failures (only written when there are any) |
| `snapshots.json` | Full record set, for re-analysis without re-querying |
| `raw\<cluster>.txt` | Untouched SSH output (only with `-SaveRaw`) |

The whole output tree is gitignored — raw captures and the JSON both carry real cluster,
SVM and volume names.

## ONTAP schema this relies on

Field names were taken from `vol snapshot show -fields ?` on a live ONTAP 9 cluster, not
from memory. The collected set is:

```
vserver, volume, snapshot, create-time, size, snapmirror-label, state, busy, owners
```

`Get-SnapshotInventoryCommand` validates every requested field against that catalog and
throws on anything else, so a typo fails locally instead of returning an empty report.

Three properties of the real CLI output drive the parser, and each has a regression test:

1. **ONTAP returns fields in its own order, not the requested order.** A request for
   `...,create-time,size,snapmirror-label,state,busy,owners` came back as
   `...,create-time,busy,owners,size,snapmirror-label,state`. Parsing is therefore driven by
   the field-name header line. Positional parsing silently swaps `size` and `busy`.
2. **The login/banner block is not a fixed number of lines** (8 in one capture, 6 in
   another). Anything that skips a fixed count either eats the first data row or accepts
   ONTAP's display-name row as a snapshot. Note that the workspace's shared
   `Invoke-OntapCsv` helper uses `awk 'NR>8'` and is exposed to exactly this; that is why
   this workflow parses the raw SSH output itself instead of reusing it.
3. **`row 0` is mandatory.** With a row limit ONTAP emits an interactive
   `Press <space> to page down` prompt and truncates the result.

### Field semantics worth knowing

- `create-time` is cluster-local time with no offset, in ctime form
  (`Wed Jul 29 00:00:18 2026`), and a single-digit day is **double**-spaced
  (`Sun Dec  1 02:00:00 2019`). Ages are calculated against the local clock, so a cluster in
  another timezone is off by that offset — irrelevant at day granularity, worth remembering
  if you ever threshold in hours.
- `size` is displayed in binary units labelled `KB`/`MB`/`GB`/`TB` (i.e. KiB/MiB/GiB/TiB).
  `-LargeThresholdGB` is likewise GiB.
- `owners` non-empty or `busy true` means the snapshot is **locked** — a clone, a dump, or
  SnapMirror is holding it. Deleting one of those is not a simple space win. The reports
  surface this as `Locked` / `LockReason` so a candidate list is never read as a safe-to-delete list.

### Unmeasured records are never faked

A snapshot whose size or creation time cannot be read gets `$null`, never `0`. Zero bytes
would sort as "smallest" and drop the record out of every largest-N ranking while still
looking like a real measurement; zero days old would do the same to the age ranking. Those
records are excluded from rankings and listed in `snapshots-unknown.csv` instead.

## Testing

```powershell
.\scripts\testing\Test-SnapshotComparisonScripts.ps1
```

70 offline checks, no cluster contact: syntax, module surface, command building and field
validation, size and timestamp parsing, the three raw-output regressions above, record
normalisation, ranking and thresholds, an end-to-end run of the real driver in
`-ReplayFrom` mode against the fixtures, the read-only guarantee, config-driven
targeting, and Script Manager registration.

Run it after any change to the module or the driver.

### Demo report from the fixtures (no cluster, no real data)

```powershell
$out = 'scripts\snapshots\reports\offline-fixture'
New-Item -ItemType Directory -Force -Path "$out\raw" | Out-Null
Copy-Item scripts\testing\fixtures\snapshots\Cluster[AB].txt "$out\raw\"
.\scripts\snapshots\Get-SnapshotComparison.ps1 -ReplayFrom $out -OutputPath $out
```

The output tree is gitignored, so regenerate it rather than expecting it in a checkout. One
`problems.csv` row is expected: `ClusterA.txt` carries a truncated line the parser must
reject instead of guess at.

## Gotcha: `Load-Config.ps1` clobbers a `-Cluster` parameter

`Load-Config.ps1`'s per-cluster generator loop assigns `$cluster` in the **caller's** scope.
PowerShell variable names are case-insensitive, so dot-sourcing it at script scope in a
script that has a `-Cluster` parameter overwrites that parameter with the *last* cluster in
`config.json` — `-Cluster <alias>` then silently reports on a different cluster. This was
observed live.

The driver dot-sources it inside a function to contain the assignment. Everything
`Load-Config.ps1` publishes is declared global, so nothing is lost. **Any other script in
this workspace with a `-Cluster` parameter is exposed to the same bug.**

## Safety

Read-only. Nothing here deletes a snapshot. If the user wants to act on a candidate list,
treat that as a separate task, confirm the specific snapshots, and check `Locked` /
`LockReason` first — see the `volume-management` skill for `snapshot autodelete` semantics.
