# NetApp ONTAP Automation Workspace

AI-assisted automation workspace for NetApp ONTAP cluster administration. Combines PowerShell SSH/CSV helpers, the DataONTAP PowerShell Toolkit, a curated case knowledge base, and a library of domain skills used by GitHub Copilot agents.

<!-- CLUSTER-TABLE:START - Auto-generated from config.json by Update-ReadmeClusterTable.ps1. Do not edit manually. -->
## Clusters

> Table auto-populated from `config.json` when `Load-Config.ps1` runs.
> Copy `config.template.json` → `config.json` and fill in your cluster details.
<!-- CLUSTER-TABLE:END -->

Copy `config.template.json` → `config.json` and fill in your cluster details. `Load-Config.ps1` auto-generates per-cluster functions:

| Function Pattern | Purpose |
|-----------------|---------|
| `<alias>` | `connect-ncController` session (ZAPI) |
| `<alias>-s [-Command "..."]` | SSH shortcut (interactive or one-shot) |
| `Get-<CsvPrefix>Csv -Command "..."` | SSH + CSV parse → PowerShell objects |

## Key PowerShell Helpers

- **`Get-<CsvPrefix>Csv -Command "<ontap cli>"`** — runs an ONTAP CLI command via SSH, parses CSV, returns objects.
- **`<alias>-s [-Command "..."]`** — direct SSH shortcut per cluster (interactive or one-shot).
- **`connect-ncController` aliases** — DataONTAP PowerShell Toolkit (ZAPI) sessions.

```powershell
# Examples (replace with your aliases from config.json)
Get-ProdCsv -Command "vol show -fields vserver,volume,size,used"
prod-s -Command "snapmirror show"
```

## Repository Layout

```
config.json                  # Cluster definitions (gitignored — real data)
config.template.json         # Template for  users (tracked)
Load-Config.ps1              # Central config loader — auto-generates functions
profile1.ps1                 # Workspace profile — modules + dot-sources Load-Config
.github/
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

## Knowledge Base

- **[.github/Netapp Cases/](.github/Netapp%20Cases/)** — One Markdown file per NetApp support case. The agent searches this first when diagnosing errors or alerts.
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
