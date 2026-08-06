---
name: workspace-netapp-code
description: Primary NetApp ONTAP automation workspace. TRIGGER when user mentions "Netapp-Code-WorkSpace" / "Netapp-Code" / "the NetApp workspace" / ONTAP cluster / Invoke-OntapCsv / Get-OntapTargetClusters / Load-Config / NetApp Cases knowledge base / `.github/skills/` directory / test connection ONTAP / check ONTAP / cluster health / health check / test all clusters / cluster status / netapp health / all clusters / netapp cluster / sas-diag / snapmirror monitor / quota / NDMP copy / DFS cleanup / delete DFS share / decommission share / File System Analytics / FSA / volumes or qtree to delete / Invoke-DFSDecommission / ForceDeletePath / OverrideManifest / VerdictFile / Script-4-Human / CAB1 sheet / DFS tracker workbook / mark for deletion / approve deletion.
---

# Netapp-Code-WorkSpace

This is the tracked, project-owned source of truth for the workspace-level skill. Claude and Hermes canonical `workspace-netapp-code/SKILL.md` files link here. Keep the detailed instruction blocks in their existing project-local files; this file is their index, not a replacement for them.

## Instruction tree

| Layer | Existing source | Use it for |
|---|---|---|
| Workspace skill | `SKILL.md` | This trigger/index and the generic workspace orientation below. |
| Shared agent instructions | `CLAUDE.md` | Always-on PowerShell/ONTAP conventions, safety, credentials, and execution boundaries for Copilot and Claude. |
| Public workspace guide | `README.MD` | Repository layout, quick start, scripts, skill links, and user-facing documentation. |
| Documentation launcher | `Start-Docs.ps1` | Documentation-source verification and Docs Hub launch. |
| Domain skill tree | `.github/skills/<name>/SKILL.md` | Capability-specific instructions and references. |

Read the matching project-local domain skill before acting on a capability:

- [DFS Cleanup](.github/skills/dfs-cleanup/SKILL.md)
- [DFS Management](.github/skills/dfs-management/SKILL.md)
- [iSCSI Management](.github/skills/iscsi-management/SKILL.md)
- [NDMP Copy](.github/skills/ndmp-copy/SKILL.md)
- [Network Management](.github/skills/network-management/SKILL.md)
- [ONTAP Cluster Info](.github/skills/ontap-cluster-info/SKILL.md)
- [PDF Knowledge Import](.github/skills/pdf-knowledge-import/SKILL.md)
- [Quota Management](.github/skills/quota-management/SKILL.md)
- [S3 Management](.github/skills/s3-management/SKILL.md)
- [Share Migration](.github/skills/share-migration/SKILL.md)
- [SnapMirror Management](.github/skills/snapmirror-management/SKILL.md)
- [Snapshot Comparison](.github/skills/snapshot-comparison/SKILL.md)
- [SVM-DR](.github/skills/svm-dr/SKILL.md)
- [SVM Management](.github/skills/svm-management/SKILL.md)
- [Volume Management](.github/skills/volume-management/SKILL.md)

## Config-driven ONTAP automation workspace

All clusters, functions, and helpers are **dynamically generated** from `config.json` at load time — nothing is hardcoded.

### Quick start (Claude Code)

```powershell
. .\profile1.ps1; <your command>
```

`profile1.ps1` dot-sources `Load-Config.ps1`, which reads `config.json` and auto-generates per-cluster functions.

### Architecture — config-driven

`config.json` (gitignored) → `Load-Config.ps1` → auto-generates **per cluster**:

| Generated item | Pattern | Example |
|---|---|---|
| Connect function | `<cluster>` | `mycluster` → `Connect-NcController` |
| SSH function | `<cluster>-ssh` | `mycluster-ssh -Command "vol show"` |
| CSV helper | `Get-<Alias>Csv` | `Get-MyCsv -Command "vol show -fields size"` |
| Aliases | `<Alias>` / `<Alias>-ssh` | When Alias differs from cluster |

Key functions:
- `Get-OntapTargetClusters [-Cluster <name>] [-VIP]` — select clusters by alias, cluster, or VIP flag
- `Invoke-OntapCsv -SshFunction <fn> -Command "..."` — generic SSH + CSV parser
- `Resolve-SshHost <cluster>` — returns the cluster host or FallbackIP

Schema: see `config.template.json` (tracked). First run auto-copies template to `config.json`.

## Data retrieval — prefer native cmdlets (SSH/CSV is the fallback)

1. **NetApp.ONTAP `Get-Nc*` cmdlets** (e.g. `Get-NcVol`, `Get-NcVserver`, `Get-NcSnapmirror`, `Get-NcNetInterface`, `Get-NcCifsShare`) — return PowerShell objects. **Use these first** for structured data, filtering, and reporting. Each `.github/skills/*/SKILL.md` lists the correct cmdlet per operation.
2. **`Get-<Alias>Csv` / `<cluster>-ssh`** — SSH + raw ONTAP CLI. **Last-resort fallback**, only when no `Get-Nc*` cmdlet exists for the operation (or for quick interactive one-offs / CLI troubleshooting).

## Knowledge base

- `KnownIssues/` (tracked) — sanitized, generic case articles. **Search first.**
- `.github/Netapp Cases/` (gitignored) — raw personal case summaries. Search when KnownIssues has no match.
- `PDF/` — official ONTAP 9 documentation

## Other components

- `scripts/` — disk/sas-diag, quota, ndmp-copy, snapmirror monitor, DR reports, snapshot tools, share-migration, dfs-cleanup, testing
- `scripts/dfs-cleanup/` — DFS share/qtree decommission driven by File System Analytics age evidence. Config: `Config_DFSCleanup.json` (gitignored). See `.github/skills/dfs-cleanup/SKILL.md` and `scripts/dfs-cleanup/README.md`. **Destructive modes require a stored verdict file — never bypass that.** Offline suite: `scripts/testing/Test-DFSCleanupScripts.ps1`, 109 checks, no cluster needed — run it after any edit.
  - `-Mode Report` updates the `CAB1` worksheet **in place** and rebuilds `Symlink_Map` / `Anomalies`. Add a UNC path to **column A** and the next run fills that row in. Never switch `CAB1` to `Export-Excel` — it replaces the sheet wholesale and would destroy the title block, the styling and the `Actual Path` formula.
  - Never written: `Comments`, `commands`, `Is Backuped`, `Actual Path`. Tool-owned and re-measured every run: everything else, including `Size (GB)`, `Status`, `Last Accessed`, `Last Modified`. A mapped column missing from the sheet is appended, not skipped.
  - **History is protected once a target is gone** — `Size (GB)`, `Last Accessed`, `Last Modified` and `Content (measured)` are left exactly as they were, because they are the only record of what was removed. Only `Status` becomes `GONE`. Do not write `n/a` over them.
  - Three traps worth knowing before touching the age engine: an empty directory is **not** zero bytes (FSA reports the inode, so `EMPTY` is keyed on file/subdirectory counts); reading a directory updates that directory's **own** atime and FSA counts the inode, so access time is self-contaminated (`$ObservationStart` exists for this and is **deliberately unused** pending an explicit maintainer decision - do not enable it unilaterally); a REST **404 means `GONE`**, not `NO_ANALYTICS`.
  - Deletion gates: `-VerdictFile` + `Approved=YES` in the row + a per-target interactive challenge (type `YES` → answer a random multiplication → type the full DFS path). **`-Force` and `-Confirm:$false` do not authorise deletion.** Only `-OverrideManifest` (dated today, naming the running account, every path listed individually) or `-ForceDeletePath` (adds a 4th challenge naming who authorised it) get past the challenge.
- `ansible/s3-bucket-provision/` — S3 bucket provisioning (WSL only). Setup: `Setup-AnsibleWSL.ps1`
- `credentials/` — AES-256 encrypted password store (for Ansible/API use, not for SSH/module auth)
- `Start-Docs.ps1` — launches HTTP docs server + opens `docs/index.html` hub
- `docs/index.html` — static SPA that renders README.MD + cluster widget from config.json

## Safety

Follow the shared safety rules in `CLAUDE.md` and the matching domain skill before any state-changing operation. Never bypass the DFS Cleanup verdict/approval gates, and always obtain explicit confirmation before destructive ONTAP operations.
