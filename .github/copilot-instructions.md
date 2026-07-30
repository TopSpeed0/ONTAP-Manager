# ONTAP Manager — Copilot Instructions

## Purpose

This workspace automates NetApp ONTAP cluster operations via PowerShell + SSH.
All cluster definitions live in `config.json` (gitignored) — never hardcode cluster names or IPs.

## Available Clusters

Clusters are loaded dynamically from `config.json` by `Load-Config.ps1`.
Each cluster entry has: `cluster`, `Alias`, `Description`, `FallbackIP`, `VIP`, `NdmpPassword`, `SnapmirrorGroup`, `MainCluster`, `ONTAP_Select`, `API_Cred`. The single `cluster` field is the cluster name/host used for connections (it replaces the former `ClusterName`/`ConnectName` pair); `CsvPrefix` is no longer a field — the CSV helper name is derived from `Alias`.

Top-level config keys: `Docs_Port`, `ONTAP_ROUser` (legacy compatibility setting), `NDMP_Config`, `S3_Config`, `DFS_Config`, `Personal_modules`.

### API_Cred (per-cluster admin credential)
Each cluster has `API_Cred` **explicitly naming** an AES-encrypted `.cred` file in `credentials/` (typically `admin_<cluster>` -> `credentials/admin_<cluster>.cred`). Because it's an explicit reference, the credential loads by that exact name even when the `cluster` value is an FQDN - e.g. cluster `cluster.example.invalid` uses `API_Cred: admin_cluster`. This credential is used for REST API calls and ZAPI connections.

### S3_Config credential notes
`S3_Config.Clusters` has per-cluster S3 settings. Each entry has a `_comment` field in `config.json` explaining why its credential differs. The key design point: `API_Cred` is for general cluster admin, while `S3_Config.CredentialName` is consumed specifically by the Ansible S3 playbook. When both point to the same credential, it's intentional duplication for Ansible's explicit reference.

After `. .\Load-Config.ps1`, the following are auto-generated **per cluster** from `config.json`:

| Generated Item | Pattern | Description |
|---|---|---|
| Connect function | `<cluster>` | Calls `Connect-NcController` |
| SSH function | `<cluster>-ssh` | `ssh admin@<host>` (uses FallbackIP if set; `-s` also works) |
| CSV helper | `Get-<Alias>Csv` | Wraps `Invoke-OntapCsv` for structured output |
| Alias (if different) | `<Alias>` → connect, `<Alias>-ssh` → SSH | Short names when Alias ≠ cluster |

Use `$global:ONTAP_Clusters` to iterate all clusters, or `Get-OntapTargetClusters` with `-VIP` or `-Cluster` parameters.

## Key PowerShell Commands

```powershell
# Load config and auto-generate cluster functions
. .\Load-Config.ps1

# Target selection
Get-OntapTargetClusters                 # all clusters
Get-OntapTargetClusters -VIP            # only VIP-marked clusters
Get-OntapTargetClusters -Cluster "Prod" # specific cluster by Alias or cluster

# SSH (raw text) — PREFERRED: per-cluster helper returns clean output
example-cluster-s "vol show -fields vserver,volume,size"     # short alias
example-cluster-ssh "vol show -fields vserver,volume,size"   # full name

# SSH (raw text) — use only when a script needs the returned object
Invoke-NcSsh -ControllerName <name> -Command "vol show -fields vserver,volume,size"

# CSV wrapper (returns parsed objects)
Invoke-OntapCsv -Cluster <obj> -Command "vol show -fields vserver,volume,size"

# Resolve SSH host (cluster or FallbackIP)
Resolve-SshHost "<cluster>"
```

## Conventions

- **Always use ONTAP CLI commands** when building automation. Prefer `Invoke-OntapCsv` for structured data.
- **SSH reads:** Prefer the per-cluster helper `<cluster>-s` (or `<cluster>-ssh`) — it returns clean raw text. Reserve `Invoke-NcSsh` for scripts that need the returned object (it wraps output in `NcController` / `Value` noise).
- **Target cluster by alias:** Use the config-driven aliases from `Get-OntapTargetClusters`.
- When the user says "cluster" without specifying, **ask which cluster** or suggest using `-VIP`.
- **Output format:** ONTAP CLI commands should use `-fields` to select specific columns. This produces cleaner CSV output.
- **Row limit:** CSV helpers already set `row 0` (unlimited). Do not add row limits.
- When automating multi-step procedures, **show the user the plan** and each command before executing.
- For destructive operations (delete, offline, destroy), **always confirm** with the user first.

## ONTAP CLI Reference

Common command patterns:
```
vol show -fields vserver,volume,size,used,aggregate
net int show -fields vserver,lif,curr-node,address,role
snapmirror show -fields source-path,destination-path,state,status
vserver show -fields vserver,type,state,allowed-protocols
aggr show -fields aggregate,size,usedsize,availsize,node
lun show -fields vserver,path,size,mapped
storage disk show -fields disk,owner,container-type,shelf,bay
storage port show
storage shelf show -fields shelf-id,state,module-type,vendor,module-fw-rev
storage errors show
storage shelf port show
event log show -severity ERROR -message-name *sas* -fields time,node,message-name,event
system health alert show
system health status show
system health subsystem show
iscsi session show -vserver <svm> -fields tpgroup,tsih,initiator-name,initiator-alias,isid
vserver iscsi connection show -vserver <svm> -fields tpgroup,tsih,remote-address,local-address,remote-ip-port
iscsi initiator show -vserver <svm>
igroup show -vserver <svm> -fields igroup,protocol,ostype
vserver object-store-server show
vserver object-store-server bucket show -vserver <svm>
vserver object-store-server user show -vserver <svm>
vserver object-store-server policy show -vserver <svm>
```

## ONTAP 9 Core Concepts

### Storage Hierarchy
Cluster → Nodes (HA Pairs) → Aggregates → Volumes → LUNs/Files. SVMs span across nodes; LIFs can migrate between nodes.

### Key Terminology
- **SVM (Vserver)**: Virtual server that owns volumes and LIFs. Data SVMs serve clients. CLI uses `vserver` command.
- **LIF**: Logical Interface — IP+port that can move between nodes non-disruptively.
- **Aggregate (Local Tier)**: Pool of physical disks on a node.
- **FlexVol**: Standard volume (max 100TB, 300TB with large-size enabled).
- **FlexGroup**: Distributed volume across member volumes (up to 60PB).
- **SnapMirror**: Async/sync replication between volumes or SVMs.
- **Junction Path**: Mount point in the SVM namespace (e.g., `/data`, `/eng/home`).

### SnapMirror Path Syntax
- **Volume-level**: `<svm_name>:<volume_name>` (e.g., `svm1:vol1`)
- **SVM-level**: `<svm_name>:` — note the **trailing colon** after the SVM name
- **XDP** is the default relationship type since ONTAP 9.4

### Version Notes
- ONTAP 9.6+: `-role` deprecated for LIFs — use `-service-policy` instead
- ONTAP 9.6+: FabricPool supported with SVM-DR
- ONTAP 9.9.1+: mirror-vault policy with independent snapshot policies on source/dest
- ONTAP 9.11.1+: `-quick-resync true` option for faster SVM-DR failback
- ONTAP 9.12.1+: Large volume support (300TB FlexVol, 128TB LUN)
- ONTAP 9.13.1+: SVM max capacity limits and alerts

## NetApp Support Cases Knowledge Base

Two folders hold case-based knowledge:

- **`KnownIssues/`** (tracked) — Sanitized, generic articles. Search here first.
- **`.github/Netapp Cases/`** (gitignored) — Raw personal case summaries with customer-specific data. Search here when `KnownIssues/` has no match.

Use `@case-sanitizer` to convert raw cases into generic KnownIssues articles.

**When the user asks about an ONTAP error, alert, or symptom, search both folders** for an existing case summary that matches before researching from scratch. Treat the contents as authoritative context for the issues they describe (root cause, workarounds, NetApp engineer guidance).

## PDF Documentation Library

NetApp documentation PDFs are stored in the `./PDF/` folder at the workspace root. When you need deeper knowledge about an ONTAP feature, procedure, or best practice:

1. Check `./PDF/` for relevant PDFs
2. Extract content using Python `pymupdf`
3. Update the relevant skill reference files under `.github/skills/<skill>/references/`

Use the `/pdf-knowledge-import` skill for the full extraction workflow.

## Credential Store

Passwords are stored as AES-256 encrypted files in `credentials/` (same pattern as HCI_Manager):
- `credentials/aes.key` — shared AES-256 encryption key (auto-generated on first use)
- `credentials/credentials.json` — credential registry mapping credential name → username (git-tracked, no secrets)
- `credentials/admin_*.cred` — per-cluster admin passwords (referenced by `API_Cred` in config.json)
- `credentials/ontap_s3.cred` — S3 dev user password (see `S3_Config._comment` in config.json)
- `credentials/vault_credentials_*.yml` — Ansible vault files for S3 playbook
- `credentials/.gitignore` — excludes `aes.key` and `*.cred` from git

### Credential Registry (`credentials/credentials.json`)
Maps each `.cred` name to its associated username. Scripts use this to resolve usernames automatically without requiring them in every config file. Resolution chain: **config override → registry → fallback**.

```powershell
# Store a new password with username (one-time, interactive)
.\scripts\credentials\New-Credential.ps1 -Name "ontap_s3" -UserName "sm_s3_dev"

# Retrieve plaintext for automation
$pwd = & .\scripts\credentials\Get-Credential.ps1 -Name "ontap_s3"

# Retrieve as PSCredential (username from registry)
$cred = & .\scripts\credentials\Get-Credential.ps1 -Name "ontap_s3" -AsPSCredential

# Retrieve as SecureString (for PSCredential workflows)
$sec = & .\scripts\credentials\Get-Credential.ps1 -Name "ontap_s3" -AsSecureString

# Retrieve password + username hashtable
$info = & .\scripts\credentials\Get-Credential.ps1 -Name "ontap_s3" -IncludeUserName
# $info.Password, $info.UserName, $info.Name
```

## Ansible

Ansible playbooks are in `ansible/`. The CLI doesn't run natively on Windows — use **WSL** for `ansible-playbook` / `ansible-vault`.

Available playbooks:
| Playbook | Purpose |
|----------|--------|
| `ansible/s3-bucket-provision/provision_s3_bucket.yml` | Create S3 buckets on a cluster |

## Script Manager

`Start-ScriptManager` (alias `sm`) provides a GUI/console launcher for workspace scripts. Loaded by `profile1.ps1`.

```powershell
Start-ScriptManager              # GUI grid view (Out-GridView)
Start-ScriptManager -Console     # Console numbered menu
sm -Filter "share"               # Pre-filter by keyword
sm -Filter "dfs"                 # DFS cleanup preflight and offline safety tests
```

The registry lives in `scripts/Start-ScriptManager.ps1`. To add a new script, append a `[pscustomobject]` entry to the `$scripts` array in that file.

## Share Migration

Export and import SMB share configuration + ACLs for SVM domain migration. Config: `Config_shareMig.json` (gitignored; template: `Config_shareMig.template.json`). Skill: `.github/skills/share-migration/`.

```powershell
# Preflight validation
.\scripts\share-migration\Invoke-ShareMigration.ps1 -Mode Preflight -ApprovePreflight

# Export shares + ACLs to JSON snapshot
.\scripts\share-migration\Invoke-ShareMigration.ps1 -Mode Export

# Import from snapshot after domain move
.\scripts\share-migration\Invoke-ShareMigration.ps1 -Mode Import -SnapshotPath <path>

# Export + Import in one pass
.\scripts\share-migration\Invoke-ShareMigration.ps1 -Mode Sync
```

## Snapshot Comparison

Read-only snapshot inventory across every configured cluster: all records, oldest, largest,
and the records crossing configurable age / size thresholds. Skill:
`.github/skills/snapshot-comparison/`.

```powershell
# All clusters, defaults (age >= 90 d, size >= 100 GiB)
.\scripts\snapshots\Get-SnapshotComparison.ps1

# One cluster, custom thresholds
.\scripts\snapshots\Get-SnapshotComparison.ps1 -Cluster <alias> -AgeDays 30 -LargeThresholdGB 50

# Capture once, re-threshold offline with no cluster contact
.\scripts\snapshots\Get-SnapshotComparison.ps1 -VIP -SaveRaw
.\scripts\snapshots\Get-SnapshotComparison.ps1 -ReplayFrom <report-dir> -AgeDays 365

# Offline tests (no cluster)
.\scripts\testing\Test-SnapshotComparisonScripts.ps1
```

Issues `vol snapshot show` only — never deletes or modifies a snapshot. Candidate lists are
for human review, and carry a `Locked` flag for snapshots held by a clone, dump or SnapMirror.

Separate from `scripts/snapshots/Get-BiggestSnapshot.ps1`, which stays as it is — that one
answers "biggest snapshots on one cluster"; this one compares every cluster and adds the age
dimension, thresholds and offline replay.

**Two traps this codifies, both worth knowing beyond this script:**

1. `vol snapshot show` returns fields in ONTAP's own order, not the requested order, and its
   banner is not a fixed number of lines. `Invoke-OntapCsv`'s `awk 'NR>8'` is exposed to
   both — it can drop the first data row or admit the display-name row as data. Parse by the
   field-name header, not by position or line count.
2. `Load-Config.ps1` assigns `$cluster` in the **caller's** scope. PowerShell names are
   case-insensitive, so dot-sourcing it at script scope in a script with a `-Cluster`
   parameter silently overwrites that parameter with the last cluster in `config.json`.
   Dot-source it inside a function; everything it publishes is global anyway.

## DFS Cleanup

`scripts/dfs-cleanup/Invoke-DFSDecommission.ps1` is the repository-local, evidence-based DFS
share/qtree/volume cleanup workflow. Read `.github/skills/dfs-cleanup/SKILL.md` and
`scripts/dfs-cleanup/README.md` before running it. The required sequence is **Preflight → Resolve
→ Report → human approval → Delete**. `Report` is evidence collection, not deletion approval.

- `-Mode Preflight` and `-Mode Resolve` are read-only discovery modes.
- `-Mode Report` may update the configured local workbook and publish its configured copy; it does
  not modify ONTAP objects.
- `-Mode Delete` is destructive and requires a stored verdict report, `Approved=YES`, a per-target
  interactive challenge, and separate confirmation for backing storage. Never invoke it from an
  unattended agent or generic launcher.
- Run `.\scripts\testing\Test-DFSCleanupScripts.ps1` after edits; it is offline and covers the
  deletion gates, subfolder classification, and FSA age-evidence safety rules.

## Session Logging

At the end of each session, save a summary of work done to `.github/session-log-<date>.md` (e.g., `session-log-2026-06-15.md`). Include: what was changed, why, key decisions, and git state. These files are gitignored.

## Safety Rules

1. Never run `vol delete`, `vol offline`, `vserver delete`, `snapmirror break`, or `snapmirror delete` without explicit user confirmation.
2. Always verify the target cluster before running commands.
3. For SVM-DR and data migration workflows, present the full plan before executing any step.
4. Do not modify network configurations without the user reviewing the changes.
