# ONTAP Manager — Copilot Instructions

## Purpose

This workspace automates NetApp ONTAP cluster operations via PowerShell + SSH.
All cluster definitions live in `config.json` (gitignored) — never hardcode cluster names or IPs.

## Available Clusters

Clusters are loaded dynamically from `config.json` by `Load-Config.ps1`.
Each cluster entry has: `ClusterName`, `ConnectName`, `Alias`, `CsvPrefix`, `Description`, `FallbackIP`, `VIP`.

After `. .\Load-Config.ps1`, the following are available per cluster:

| Generated Item | Pattern | Example (Alias=Prod, CsvPrefix=A1k) |
|---|---|---|
| Connect function | `Connect-<Alias>` | `Connect-Prod` |
| SSH function | `<ConnectName>-s` | `Prod-prd-s` |
| CSV helper | `Get-<CsvPrefix>Csv` | `Get-A1kCsv` |
| SSH alias | `<Alias>` lowercased | `prod-s` |

Use `$global:ONTAP_Clusters` to iterate all clusters, or `Get-OntapTargetClusters` with `-VIP` or `-Cluster` parameters.

## Key PowerShell Commands

```powershell
# Load config and auto-generate cluster functions
. .\Load-Config.ps1

# Target selection
Get-OntapTargetClusters                 # all clusters
Get-OntapTargetClusters -VIP            # only VIP-marked clusters
Get-OntapTargetClusters -Cluster "Prod" # specific cluster by Alias or ClusterName

# SSH (returns raw text)
Invoke-NcSsh -ControllerName <name> -Command "vol show -fields vserver,volume,size"

# CSV wrapper (returns parsed objects)
Invoke-OntapCsv -Cluster <obj> -Command "vol show -fields vserver,volume,size"

# Resolve SSH host (ConnectName or FallbackIP)
Resolve-SshHost "<ClusterName>"
```

## Conventions

- **Always use ONTAP CLI commands** when building automation. Prefer `Invoke-OntapCsv` for structured data.
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

The folder `.github/Netapp Cases/` is a curated knowledge base of NetApp support case summaries — one Markdown file per case, named like `NetApp Case Summary – <case#> (<short tag>).md`. The user adds to this folder over time.

**When the user asks about an ONTAP error, alert, or symptom, search this folder first** for an existing case summary that matches before researching from scratch. Treat the contents as authoritative context for the issues they describe (root cause, workarounds, NetApp engineer guidance).

## PDF Documentation Library

NetApp documentation PDFs are stored in the `./PDF/` folder at the workspace root. When you need deeper knowledge about an ONTAP feature, procedure, or best practice:

1. Check `./PDF/` for relevant PDFs
2. Extract content using Python `pymupdf`
3. Update the relevant skill reference files under `.github/skills/<skill>/references/`

Use the `/pdf-knowledge-import` skill for the full extraction workflow.

## Credential Store

Passwords are stored as AES-256 encrypted files in `credentials/` (same pattern as HCI_Manager):
- `credentials/aes.key` — shared AES-256 encryption key (auto-generated on first use)
- `credentials/*.cred` — encrypted password files (one per service)
- `credentials/.gitignore` — excludes `aes.key` and `*.cred` from git

```powershell
# Store a new password (one-time, interactive)
.\credentials\New-Credential.ps1 -Name "ontap_s3"

# Retrieve plaintext for automation
$pwd = & .\credentials\Get-Credential.ps1 -Name "ontap_s3"
```

## Ansible

Ansible playbooks are in `ansible/`. The CLI doesn't run natively on Windows — use **WSL** for `ansible-playbook` / `ansible-vault`.

Available playbooks:
| Playbook | Purpose |
|----------|--------|
| `ansible/s3-bucket-provision/provision_s3_bucket.yml` | Create S3 buckets on a cluster |

## Safety Rules

1. Never run `vol delete`, `vol offline`, `vserver delete`, `snapmirror break`, or `snapmirror delete` without explicit user confirmation.
2. Always verify the target cluster before running commands.
3. For SVM-DR and data migration workflows, present the full plan before executing any step.
4. Do not modify network configurations without the user reviewing the changes.
