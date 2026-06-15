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
credentials/                 # AES-encrypted credential store
  New-Credential.ps1         # Store a password (AES-256 encrypt → .cred)
  Get-Credential.ps1         # Retrieve a stored password (plaintext or SecureString)
scripts/
  disk/                      # SAS/shelf diagnostics (sas-diag.ps1)
  ndmp-copy/                 # NDMP cross-cluster file copy (Ndmp_Copy.ps1, ndmp-copy.bat)
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
- [ndmp-copy](.github/skills/ndmp-copy/) — NDMP cross-cluster file copy (prerequisites, procedure, config)
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

Config-driven cross-cluster (or same-cluster) file copy via NDMP. All parameters default from `NDMP_Config` in `config.json`. Requires `NetApp.ONTAP` module. A batch wrapper (`ndmp-copy.bat`) is also available for quick command-line use.

See [ndmp-copy skill](.github/skills/ndmp-copy/SKILL.md) for prerequisites, NDMP enable steps, and detailed procedure.

```powershell
# Zero-config — uses SrcCluster, DstCluster, SRC, DST from config.json:
.\scripts\ndmp-copy\Ndmp_Copy.ps1

# Override with explicit params:
.\scripts\ndmp-copy\Ndmp_Copy.ps1 -SrcCluster SrcAlias -DstCluster DstAlias -SourcePath "/src_svm/src_vol/path" -DestPath "/dst_svm/dst_vol/path"

# Batch wrapper (positional args or zero-config):
.\scripts\ndmp-copy\ndmp-copy.bat
```

### Biggest Snapshots (`scripts/snapshots/Get-BiggestSnapshot.ps1`)

Queries all clusters via SSH and reports the top 20 largest snapshots.

```powershell
.\scripts\snapshots\Get-BiggestSnapshot.ps1
```

### Test ONTAP User (`scripts/testing/Test-NetappROUser.ps1`)

Tests ONTAP user credentials against all clusters defined in `config.json`. Loads the password from the credential store (`credentials/<UserName>.cred`) if available, otherwise prompts interactively. Reports a table with Cluster, Status (OK/FAILED), Version, and Name.

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `-UserName` | string | No | `ONTAP_ROUser` from config.json | The ONTAP user name to test |

```powershell
# Test the default read-only user from config.json
.\scripts\testing\Test-NetappROUser.ps1

# Test a specific user (prompts for password if no .cred file)
.\scripts\testing\Test-NetappROUser.ps1 -UserName admin
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
Files `aes.key` and `*.cred` are `.gitignore`d.

### `New-Credential.ps1` — Store a Password

Encrypts a password using AES-256 and saves it as a `.cred` file. Auto-generates `aes.key` on first use.

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `-Name` | string | Yes | — | Name for the credential file (saved as `<Name>.cred`) |
| `-Force` | switch | No | — | Overwrite existing `.cred` file without prompting |

```powershell
# One-time: store a password (prompts interactively)
.\credentials\New-Credential.ps1 -Name "ontap_s3"

# Overwrite an existing credential
.\credentials\New-Credential.ps1 -Name "ontap_s3" -Force
```

### `Get-Credential.ps1` — Retrieve a Password

Decrypts a `.cred` file using the shared AES key. Returns plaintext by default.

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `-Name` | string | Yes | — | Name of the credential file to decrypt |
| `-AsSecureString` | switch | No | — | Return `[SecureString]` instead of plaintext |

```powershell
# Retrieve plaintext (for Ansible, CLI, env vars)
$pwd = & .\credentials\Get-Credential.ps1 -Name "ontap_s3"

# Retrieve as SecureString (for PSCredential workflows)
$sec = & .\credentials\Get-Credential.ps1 -Name "ontap_s3" -AsSecureString
```

## Ansible

Ansible CLI doesn't run natively on Windows. Use **WSL** (`wsl -d Ubuntu-22.04`, Ansible at `~/.local/bin/`).

### First-Time Setup

A setup script automates WSL prerequisites. Manual steps are listed below for reference.

**Automated (recommended):**

```powershell
# 1. Store your ONTAP credentials (one-time, interactive prompts)
.\credentials\New-Credential.ps1 -Name "ontap_s3"     # ONTAP password for S3 cluster
.\credentials\New-Credential.ps1 -Name "vault_key"    # Ansible vault master password

# 2. Install Ansible in WSL + create encrypted vault file
.\ansible\s3-bucket-provision\Setup-AnsibleWSL.ps1 -SetupVault -Cluster <cluster-alias>

# 3. Test (dry-run — shows command without executing)
.\ansible\s3-bucket-provision\Invoke-S3Provision.ps1 -Cluster <cluster-alias> -BucketName test -DryRun
```

`Setup-AnsibleWSL.ps1` does the following automatically:
1. Installs `ansible` and `netapp-lib` via pip in WSL
2. Installs the `netapp.ontap` Ansible Galaxy collection
3. Creates a vault credentials YAML from the credential store and encrypts it with `ansible-vault`

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-SetupVault` | No | — | Also create + encrypt vault file for a cluster |
| `-Cluster` | With `-SetupVault` | — | Cluster alias from `config.json` |
| `-SkipInstall` | No | — | Skip pip/collection install (vault only) |
| `-WslDistro` | No | `Ubuntu-22.04` | WSL distribution name |

**Manual steps (if you prefer not to use the script):**

```bash
# In WSL (wsl -d Ubuntu-22.04):

# 1. Install Ansible + NetApp library
pip install --user ansible netapp-lib

# 2. Install the ONTAP Ansible collection
ansible-galaxy collection install netapp.ontap

# 3. Create vault credentials file from template
cd <workspace>/ansible/s3-bucket-provision/credentials
cp vault_template.yml vault_credentials_<cluster>.yml
# Edit the file — replace CHANGEME with the real ONTAP password:
nano vault_credentials_<cluster>.yml

# 4. Encrypt the file (enter your vault master password when prompted)
ansible-vault encrypt vault_credentials_<cluster>.yml

# 5. (Optional) Store the vault master password for non-interactive use
echo 'YOUR_VAULT_PASSWORD' > ~/.vault_pass && chmod 600 ~/.vault_pass
```

Back in PowerShell, store the same passwords in the credential store so `Invoke-S3Provision.ps1` can use them:

```powershell
.\credentials\New-Credential.ps1 -Name "ontap_s3"     # same ONTAP password used in step 3
.\credentials\New-Credential.ps1 -Name "vault_key"    # same vault master password from step 4
```

### S3 Bucket Provisioning (`ansible/s3-bucket-provision/`)

Automates S3 bucket creation on ONTAP using the `netapp.ontap` Ansible collection.

**Playbooks:**

| Playbook | Description |
|----------|-------------|
| `provision_s3_bucket_generic.yml` | Generic — works with any cluster/SVM (pass connection vars via `-e`) |
| `provision_s3_bucket_admin.yml` | Site-specific, cluster admin credentials (gitignored) |
| `provision_s3_bucket_dev.yml` | Site-specific, SVM dev user credentials (gitignored) |

**Quick start:**

```bash
# Install prerequisites
pip install ansible netapp-lib
ansible-galaxy collection install netapp.ontap

# Set vault password (one-time)
echo 'YOUR_VAULT_PASSWORD' > ~/.vault_pass && chmod 600 ~/.vault_pass

# Provision a bucket (generic playbook — pass all connection params)
ansible-playbook ansible/s3-bucket-provision/provision_s3_bucket_generic.yml \
  -e "ontap_hostname=<cluster-name> ontap_vserver=<s3-svm> ontap_password=<password> bucket_name=my-bucket"
```

**From PowerShell (wrapper — recommended):**

`Invoke-S3Provision.ps1` resolves cluster hostname, SVM, S3 user, credentials, and vault file from `config.json` (`S3_Config` section) automatically. Only `-Cluster` and `-BucketName` are mandatory when `S3_Config` is defined:

```powershell
# Minimal — everything from config.json S3_Config
.\ansible\s3-bucket-provision\Invoke-S3Provision.ps1 `
  -Cluster <cluster-alias> -BucketName my-bucket

# Another cluster — all details from config
.\ansible\s3-bucket-provision\Invoke-S3Provision.ps1 `
  -Cluster <cluster-alias-2> -BucketName data-lake

# Vault mode — uses vault_key.cred + vault credentials file from config
.\ansible\s3-bucket-provision\Invoke-S3Provision.ps1 `
  -Cluster <cluster-alias> -BucketName my-bucket -UseVault

# Override S3 user from config
.\ansible\s3-bucket-provision\Invoke-S3Provision.ps1 `
  -Cluster <cluster-alias-2> -BucketName data-lake -S3User custom-user

# Custom size
.\ansible\s3-bucket-provision\Invoke-S3Provision.ps1 `
  -Cluster <cluster-alias> -BucketName big-bucket -BucketSize 500GB

# Dry-run — shows the ansible-playbook command without executing
.\ansible\s3-bucket-provision\Invoke-S3Provision.ps1 `
  -Cluster <cluster-alias> -BucketName test -DryRun
```

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-Cluster` | **Yes** | — | Cluster alias or name from `config.json` |
| `-BucketName` | **Yes** | — | S3 bucket name |
| `-Vserver` | No | from `S3_Config` | SVM name hosting the S3 server |
| `-S3User` | No | from `S3_Config` | S3 user granted access via bucket policy |
| `-CredentialName` | No | from `S3_Config` | Name of `.cred` file in `credentials/` |
| `-UseVault` | No | — | Use vault-based auth instead of direct creds |
| `-VaultFile` | No | from `S3_Config` | Vault credentials YAML (relative to playbook dir) |
| `-OntapUsername` | No | `admin` | ONTAP login user |
| `-BucketSize` | No | `100GB` | Human-readable size (min ~95 GB) |
| `-DryRun` | No | — | Show command without executing |

`config.json` S3_Config section maps per-cluster defaults:

```json
"S3_Config": {
  "Clusters": {
    "<cluster-alias>": {
      "Vserver": "<s3-svm-name>",
      "S3User": "<s3-object-user>",
      "OntapUsername": "admin",
      "CredentialName": "<cred-file-name>",
      "VaultFile": "credentials/<vault-file>.yml"
    }
  }
}
```

**From WSL directly (manual):**

```powershell
$pw = & .\credentials\Get-Credential.ps1 -Name "ontap_s3"
wsl -d Ubuntu-22.04 -- bash --norc --noprofile -c "export PATH=/usr/local/bin:/usr/bin:/bin:`$HOME/.local/bin; cd '<workspace-wsl-path>/ansible/s3-bucket-provision'; ansible-playbook provision_s3_bucket_generic.yml -e 'ontap_hostname=<cluster-name> ontap_vserver=<s3-svm> ontap_password=$pw bucket_name=my-bucket'"
```

**Variables:**

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `bucket_name` | **Yes** | — | S3 bucket name |
| `bucket_size` | No | `107374182400` (100 GB) | Bucket size in bytes (min ~95 GB) |
| `bucket_comment` | No | `"Provisioned by Ansible DevOps automation"` | Bucket description |
| `s3_user` | No | `<s3-user>` | S3 user granted access via bucket policy |
| `ontap_hostname` | **Yes** | — | Cluster or SVM management hostname/IP |
| `ontap_vserver` | **Yes** | — | SVM name |
| `ontap_username` | No | `admin` | ONTAP user |
| `ontap_password` | **Yes** | — | ONTAP password (or use vault) |

Vault credentials are stored in `ansible/s3-bucket-provision/credentials/` (encrypted with `ansible-vault`, gitignored). The vault master password is stored in both WSL (`~/.vault_pass`) and the PowerShell credential store (`credentials/vault_key.cred`).

**Troubleshooting tip:** If Ansible returns `400 Bad Request` against an SVM LIF, ensure the LIF's service policy does NOT include `data-s3-server` — S3 hijacks port 443 and breaks REST API. Use separate LIFs for S3 data and management.
