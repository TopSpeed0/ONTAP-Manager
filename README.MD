# NetApp ONTAP Automation Workspace

AI-assisted automation workspace for NetApp ONTAP cluster administration. Combines PowerShell SSH/CSV helpers, the DataONTAP PowerShell Toolkit, a curated case knowledge base, and a library of domain skills used by GitHub Copilot agents.

## Quick Start

```powershell
# 1. Clone the repo
git clone <repo-url> && cd Netapp-Code-WorkSpace

# 2. First run — creates config.json from template automatically
. .\Load-Config.ps1
# ⚠ Edit config.json with your real cluster names, then re-run:
. .\Load-Config.ps1

# 3. You're ready — every cluster now has auto-generated functions:
<ConnectName>-s -Command "vol show"           # SSH one-liner
Get-<CsvPrefix>Csv -Command "vol show -fields vserver,volume,size,used"  # CSV → objects
<ConnectName>                                  # Connect-NcController session (ZAPI)
```

> **What happens on `. .\Load-Config.ps1`?**
> 1. If `config.json` doesn't exist, copies `config.template.json` → `config.json` and stops
> 2. Reads `config.json`, builds `$global:ONTAP_Clusters` array
> 3. Auto-generates per-cluster functions: `<ConnectName>`, `<ConnectName>-s`, `Get-<CsvPrefix>Csv`, aliases
> 4. Loads personal modules from `Personal_modules` in config.json
> 5. Sets up ONTAP credentials (Jenkins env vars or interactive fallback)
> 6. One-liner to launch everything: `.\Start-Docs.ps1` — checks Python, starts docs hub, loads config

### One-Liner Launch

```powershell
.\Start-Docs.ps1
```

This single script:
- Checks if Python is installed (auto-installs via `winget` if missing)
- Starts an HTTP server on the port from `config.json` (`Docs_Port`, default `8080`)
- Opens the docs hub in your browser
- Dot-sources `Load-Config.ps1` so all cluster functions are ready in your session

Copy `config.template.json` → `config.json` and fill in your cluster details. `Load-Config.ps1` auto-generates per-cluster functions:

## Clusters

<!-- Dynamically replaced by the docs hub with a rich table from config.json -->

| Function Pattern | Purpose |
|-----------------|---------|
| `<ConnectName>` | `Connect-NcController` session (ZAPI) |
| `<ConnectName>-s [-Command "..."]` | SSH shortcut (interactive or one-shot) |
| `Get-<CsvPrefix>Csv -Command "..."` | SSH + CSV parse → PowerShell objects |
| `<Alias>` / `<Alias>-s` | Short aliases (when Alias ≠ ConnectName) |

## Key PowerShell Helpers

- **`Get-<CsvPrefix>Csv -Command "<ontap cli>"`** — runs an ONTAP CLI command via SSH, parses CSV, returns objects.
- **`<alias>-s [-Command "..."]`** — direct SSH shortcut per cluster (interactive or one-shot).
- **`connect-ncController` aliases** — DataONTAP PowerShell Toolkit (ZAPI) sessions.

```powershell
# Examples (replace <ConnectName> and <CsvPrefix> with your values from config.json)
Get-<CsvPrefix>Csv -Command "vol show -fields vserver,volume,size,used"
<ConnectName>-s -Command "snapmirror show"
```

## Repository Layout

```
config.json                  # Cluster definitions (gitignored — real data)
config.template.json         # Template for  users (tracked)
Load-Config.ps1              # Central config loader — auto-generates functions
Start-Docs.ps1               # One-liner: Python check + docs server + config load
profile1.ps1                 # Workspace profile — modules + dot-sources Load-Config
.github/
  agents/                    # Custom Copilot agents (@sanitizer, etc.)
  copilot-instructions.md    # Agent instructions & conventions
  Netapp Cases/              # Curated NetApp support case summaries (KB)
  skills/                    # Domain skills loaded by the agent
ansible/
  s3-bucket-provision/       # Ansible playbook for S3 bucket provisioning
credentials/                 # AES-encrypted credential store (aes.key + *.cred)
scripts/
  disk/                      # SAS/shelf diagnostics (sas-diag.ps1)
  ndmp-copy/                 # NDMP cross-cluster file copy
  quota/                     # Qtree quota manager
  reports/                   # NI DR reports (SSH + ZAPI versions)
  snapmirror/                # SnapMirror monitoring
  snapshots/                 # Snapshot analysis
  testing/                   # Cluster connectivity tests
PDF/                         # NetApp documentation PDFs
```

## Skills

Each fer under [.github/skills/](.github/skills/) contains a `SKILL.md` with scoped instructions and references:

- [dfs-management](.github/skills/dfs-management/) — DFS namespace / CIFS widelink resolution
- [iscsi-management](.github/skills/iscsi-management/) — iSCSI sessions, connections, igroups
- [network-management](.github/skills/network-management/) — LIFs, broadcast domains, routes, VLANs
- [ontap-cluster-info](.github/skills/ontap-cluster-info/) — Cluster reconnaissance & inventory
- [pdf-knowledge-import](.github/skills/pdf-knowledge-import/) — Extract PDF docs into skill references
- [s3-management](.github/skills/s3-management/) — ONTAP S3 servers, buckets, users, policies
- [snapmirror-management](.github/skills/snapmirror-management/) — Volume & SVM SnapMirror lifecycle
- [svm-dr](.github/skills/svm-dr/) — SVM-DR setup, failover, failback
- [svm-management](.github/skills/svm-management/) — SVM creation, NAS/SAN protocol config
- [volume-management](.github/skills/volume-management/) — Volume create/resize/move/clone

## Agents

Custom agents live in [.github/agents/](.github/agents/) and appear in the VS Code chat agent picker (`@`):

| Agent | Description | Example |
|-------|-------------|---------|
| `@sanitizer` | Scrub sensitive data from files for the public repo | `@sanitizer clean scripts/quota/Clusters Quota Policy Manger.ps1` |
| `@documenter` | Audit & enhance docs for a script across README, copilot-instructions, and skills | `@documenter scripts/disk/sas-diag.ps1` |
| `@case-sanitizer` | Convert personal NetApp cases to generic KnownIssues articles | `@case-sanitizer all` |

`@sanitizer` scans a file for hardcoded cluster names, IPs, FQDNs, personal paths, and credentials (cross-referencing `config.json`), replaces them with generic `<placeholder>` patterns, then updates README, copilot-instructions, and skill files if they reference the changed content. Finishes with a verification grep.

## Scripts

### DR Report (`scripts/reports/Get-DR-Report.ps1`)

SnapMirror DR coverage report — groups clusters by `SnapmirrorGroup` from `config.json`.

```powershell
# All groups
.\scripts\reports\Get-DR-Report.ps1

# Corp group only
.\scripts\reports\Get-DR-Report.ps1 -SMirrorG Corp

# NI group only
.\scripts\reports\Get-DR-Report.ps1 -SnapmirrorGroup NI
```

Outputs a CSV with per-volume DR status, outbound/inbound mirrors, health, lag, and a per-group summary.

### Quota Manager (`scripts/quota/Clusters Quota Policy Manger.ps1`)

Interactive qtree quota viewer and resizer. Auto-connects to the first `MainCluster` from config if no cluster session is active.

```powershell
.\scripts\quota\Clusters Quota Policy Manger.ps1
```

### NDMP Copy (`scripts/ndmp-copy/Ndmp_Copy.ps1`)

Config-driven cross-cluster file copy via NDMP. All parameters default from `NDMP_Config` in `config.json`.

```powershell
# Zero-config — uses SrcCluster, DstCluster, SRC, DST from config.json:
.\scripts\ndmp-copy\Ndmp_Copy.ps1

# Override with explicit params:
.\scripts\ndmp-copy\Ndmp_Copy.ps1 -SrcCluster SrcAlias -DstCluster DstAlias -SourcePath "/src_svm/src_vol/path" -DestPath "/dst_svm/dst_vol/path"
```

### Biggest Snapshots (`scripts/snapshots/Get-BiggestSnapshot.ps1`)

Queries all clusters via SSH and reports the top 20 largest snapshots.

```powershell
.\scripts\snapshots\Get-BiggestSnapshot.ps1
```

### SAS Diagnostics (`scripts/disk/sas-diag.ps1`)

Comprehensive SAS / disk / shelf connectivity diagnostics for any ONTAP cluster. Runs 11 checks via SSH and resolves the cluster from `config.json`. Verifies SSH connectivity before running.

Exported function: **`Get-SasDiag`**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `-Cluster` | string | Yes (positional) | Cluster name or alias from `config.json` |
| `-Shelf` | int | No | Limit disk-path detail (step 9) to a specific shelf |
| `-Export` | switch | No | Export flat results to `<Cluster>_SAS_diag.csv` |
| `-Json` | switch | No | Export structured/parsed results to `<Cluster>_SAS_diag.json` (preferred) |

```powershell
# Dot-source to load the function
. .\scripts\disk\sas-diag.ps1

# Console output only
Get-SasDiag <ClusterName>

# Filter to a specific shelf
Get-SasDiag <ClusterName> -Shelf 2

# Structured JSON export (preferred — parses -fields commands into objects)
Get-SasDiag <ClusterName> -Json

# Flat CSV export
Get-SasDiag <ClusterName> -Export
```

See [ontap-cluster-info skill](.github/skills/ontap-cluster-info/SKILL.md) for the full list of 11 diagnostic checks.

## Knowledge Base

- **[KnownIssues/](KnownIssues/)** — Generic, sanitized ONTAP known-issue articles (tracked in git). Generated from personal case files by `@case-sanitizer`.
- **`.github/Netapp Cases/`** — Raw NetApp support case summaries (gitignored — personal data). The agent searches this first when diagnosing errors or alerts.
- **[PDF/](PDF/)** — NetApp documentation PDFs, imported into skill references via the `pdf-knowledge-import` skill.

## Conventions

- Prefer `Get-<CsvPrefix>Csv` for structured ONTAP data; use `-fields` to select specific columns.
- When the user says "cluster" without an alias, ask which one.
- Show the plan before executing multi-step procedures.
- **Always confirm** destructive ops (`vol delete`, `vol offline`, `vserver delete`, `snapmirror break`, `snapmirror delete`).

## Personal Scripts Library

Point the agent to your local scripts folder in `.github/copilot-instructions.md`. Existing modules like `Get-DFSNameSpaceRoot.psm1` and `Get-NcVolAvil.psm1` are loaded by `Load-Config.ps1`.

## See Also

- Full agent instructions: [.github/copilot-instructions.md](.github/copilot-instructions.md)

## Credential Store

Passwords are stored as AES-256 encrypted files in `credentials/` (same pattern as HCI_Manager).

```powershell
# One-time: store a password
.\credentials\-Credential.ps1 -Name "ontap_s3"

# Retrieve plaintext (for Ansible, CLI, etc.)
$pwd = & .\credentials\Get-Credential.ps1 -Name "ontap_s3"
```

Files `aes.key` and `*.cred` are `.gitignore`d.

## Ansible

Ansible CLI doesn't run natively on Windows. Use **WSL** (`wsl -d Ubuntu-22.04`, Ansible at `~/.local/bin/`).

```powershell
# S3 bucket provisioning
$pwd = & .\credentials\Get-Credential.ps1 -Name "ontap_s3"
ansible-playbook ansible/s3-bucket-provision/provision_s3_bucket.yml -e "ontap_password=$pwd bucket_name=my-bucket"
```
