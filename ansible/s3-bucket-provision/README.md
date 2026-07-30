# S3 Bucket Provisioning

Automates S3 bucket provisioning on ONTAP using the `netapp.ontap` Ansible collection.

---

## Architecture

```
<cluster> (<cluster-mgmt-ip>)
└── SVM: <s3-svm>
    ├── <mgmt-lif>  <mgmt-ip>  ← REST API (management)
    │   service-policy: default-management
    │
    └── <s3-data-lif>  <s3-ip>  ← S3 data endpoint
        DNS: <s3-fqdn>
        service-policy: <custom-s3-policy>
        (data-s3-server, data-nfs, data-cifs, ...)
```

**Two LIFs, two purposes:**
- **MGMT LIF** — serves ONTAP REST API, System Manager, SSH. Used by Ansible.
- **S3 Data LIF** — serves S3 protocol only. Used by S3 clients (aws-cli, rclone, app SDKs).

---

## Playbooks

| Playbook | Description |
|----------|-------------|
| `provision_s3_bucket_generic.yml` | Generic — works with any cluster/SVM (pass connection vars via `-e`) |
| `provision_s3_bucket_admin.yml` | Site-specific, cluster admin credentials (gitignored) |
| `provision_s3_bucket_dev.yml` | Site-specific, SVM dev user credentials (gitignored) |

Both admin/dev playbooks create an S3 bucket with a bucket policy granting the configured S3 user full access (Get/Put/Delete/List).

---

## Quick Start

### 1. Install prerequisites

```bash
# Python packages
pip install ansible netapp-lib

# ONTAP Ansible collection
ansible-galaxy collection install netapp.ontap
```

> **Windows users:** Ansible doesn't run natively on Windows. Use **WSL** (Ubuntu-22.04).

### 2. Set vault password (one-time)

```bash
# The vault password decrypts the vault_credentials_*.yml files
echo 'YOUR_VAULT_PASSWORD' > ~/.vault_pass
chmod 600 ~/.vault_pass
```

### 3. Provision a bucket

```bash
cd ansible/s3-bucket-provision/

# Generic playbook — pass all connection details
ansible-playbook provision_s3_bucket_generic.yml \
  -e "ontap_hostname=<cluster> ontap_vserver=<s3-svm> ontap_password=<password> bucket_name=my-bucket"

# With vault-encrypted credentials
ansible-playbook provision_s3_bucket_generic.yml \
  --vault-password-file ~/.vault_pass \
  -e "@credentials/vault_credentials_<cluster>.yml" \
  -e "ontap_hostname=<cluster> ontap_vserver=<s3-svm> bucket_name=my-bucket"

# Custom size (500GB)
ansible-playbook provision_s3_bucket_generic.yml \
  -e "ontap_hostname=<cluster> ontap_vserver=<s3-svm> ontap_password=<password> bucket_name=my-bucket bucket_size=536870912000"
```

### Run from Windows (PowerShell → WSL)

Since Ansible doesn't run on Windows, use WSL:

```powershell
# Using Invoke-S3Provision.ps1 wrapper (recommended — reads config.json):
.\ansible\s3-bucket-provision\Invoke-S3Provision.ps1 `
  -Cluster <cluster-alias> -BucketName my-bucket

# Dry-run — shows the ansible-playbook command without executing
.\ansible\s3-bucket-provision\Invoke-S3Provision.ps1 `
  -Cluster <cluster-alias> -BucketName my-bucket -DryRun

# Manual WSL one-liner:
$pw = & .\scripts\credentials\Get-Credential.ps1 -Name "<cred-name>"
wsl -d Ubuntu-22.04 -- bash --norc --noprofile -c "export PATH=/usr/local/bin:/usr/bin:/bin:`$HOME/.local/bin; cd '<wsl-workspace-path>/ansible/s3-bucket-provision'; ansible-playbook provision_s3_bucket_generic.yml -e 'ontap_hostname=<cluster> ontap_vserver=<s3-svm> ontap_password=$pw bucket_name=my-bucket'"
```

---

## Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `bucket_name` | **Yes** | — | S3 bucket name |
| `bucket_size` | No | `107374182400` (100 GB) | Bucket size in bytes (min ~95 GB) |
| `bucket_comment` | No | `"Provisioned by Ansible DevOps automation"` | Bucket description |
| `s3_user` | No | `<s3-object-user>` | S3 user granted access via bucket policy |
| `ontap_hostname` | **Yes** | — | Cluster or SVM management hostname/IP |
| `ontap_vserver` | **Yes** | — | SVM name |
| `ontap_username` | No | `admin` | ONTAP user |
| `ontap_password` | **Yes** | — | ONTAP password (or use vault) |

---

## Credential Management

Each playbook can use its own vault file (encrypted with `ansible-vault`):

| File | Contains | For |
|------|----------|-----|
| `credentials/vault_credentials_<cluster>.yml` | `ontap_password` for that cluster | Vault-based auth |
| `credentials/vault_template.yml` | Template with `CHANGEME` placeholder | Starting point |

All vault files share the same vault unlock password (stored in `~/.vault_pass`).

### Editing vault credentials

```bash
# View (read-only)
ansible-vault view credentials/vault_credentials_<cluster>.yml --vault-password-file ~/.vault_pass

# Decrypt → edit → re-encrypt
ansible-vault decrypt credentials/vault_credentials_<cluster>.yml --vault-password-file ~/.vault_pass
# ... edit the file ...
ansible-vault encrypt credentials/vault_credentials_<cluster>.yml --vault-password-file ~/.vault_pass
```

### Quick-set a new vault ONTAP password (one-liner)

Creates (or replaces) a vault file with a new ONTAP password — prompts securely, no password in shell history:

```bash
wsl -d Ubuntu-22.04 -- bash --norc --noprofile -c 'export PATH=/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin; \
  cd "<wsl-workspace-path>/ansible/s3-bucket-provision"; \
  ansible-vault decrypt credentials/vault_credentials_<cluster>.yml --vault-password-file ~/.vault_pass 2>/dev/null; \
  read -sp "Enter ONTAP password: " PW; echo; \
  echo "---" > credentials/vault_credentials_<cluster>.yml; \
  echo "ontap_password: \"$PW\"" >> credentials/vault_credentials_<cluster>.yml; \
  ansible-vault encrypt credentials/vault_credentials_<cluster>.yml --vault-password-file ~/.vault_pass; \
  echo "Done"'
```

### Vault master password

All vault files are encrypted with a single **vault master password** — stored in:

| Store | Location | Retrieve |
|-------|----------|----------|
| WSL | `~/.vault_pass` (chmod 600) | `cat ~/.vault_pass` |
| PowerShell | `credentials/vault_key.cred` | `.\scripts\credentials\Get-Credential.ps1 -Name "vault_key"` |

This is NOT an ONTAP password. It's a separate key used only to lock/unlock vault files.

### Restore ~/.vault_pass from PowerShell credential store

If WSL is reset or `~/.vault_pass` is lost, restore from the workspace AES credential store:

```powershell
$vp = & .\scripts\credentials\Get-Credential.ps1 -Name "vault_key"
wsl -d Ubuntu-22.04 -- bash -c "echo '$vp' > ~/.vault_pass && chmod 600 ~/.vault_pass && echo 'Restored'"
```

---

## Troubleshooting

### "400 Client Error: Bad Request for url: /api/cluster?fields=version"

**Root cause:** The SVM management LIF has `data-s3-server` in its service policy.
When S3 and HTTPS share the same LIF, the S3 protocol hijacks port 443 — REST API
calls get routed to the S3 engine, which returns XML like:

```xml
<Error><Code>InvalidRequest</Code>
<Message>The authorization mechanism you have provided is not supported.
Please use AWS4-HMAC-SHA256.</Message></Error>
```

The `netapp.ontap` collection interprets this as a `400 Bad Request`.

**Fix:** The SVM MGMT LIF must use a service policy **without** `data-s3-server`:

```
# Check current policy
net int show -vserver <s3-svm> -fields service-policy

# Fix: switch MGMT LIF to default-management
net int modify -vserver <s3-svm> -lif <mgmt-lif> \
  -service-policy default-management

# Verify the S3 data LIF keeps its own policy (with data-s3-server)
net int show -vserver <s3-svm> -fields service-policy
```

**Rule of thumb:** Separate your LIFs — S3 data on one LIF, management on another.

### "User is not authorized"

Check that:
1. The user has `http` application login: `security login show -vserver <s3-svm> -user-or-group-name <username>`
2. The role has REST API access: `security login rest-role show -vserver <s3-svm> -role vsadmin -api /api/protocols/s3/*`
3. The password is correct (test with curl):
   ```bash
   curl -sk -u '<username>:<password>' 'https://<mgmt-ip>/api/cluster?fields=version'
   ```

### Ansible doesn't run on Windows

Ansible uses POSIX blocking I/O checks that fail on Windows with:
```
OSError: [WinError 1] Incorrect function
```
Use **WSL** (Ubuntu-22.04). Ansible is installed at `~/.local/bin/`.

### WSL can't reach cluster IPs

WSL2 NAT mode can't route to corporate subnets. Fix:
```
# Create C:\Users\<you>\.wslconfig
[wsl2]
networkingMode=mirrored
```
Then restart WSL: `wsl --shutdown`

---

## File Layout

```
ansible/s3-bucket-provision/
├── provision_s3_bucket_generic.yml   # Generic playbook — any cluster/SVM (tracked)
├── provision_s3_bucket_admin.yml     # Site-specific admin (gitignored)
├── provision_s3_bucket_dev.yml       # Site-specific dev user (gitignored)
├── provision_s3_bucket.yml           # Legacy (gitignored)
├── Invoke-S3Provision.ps1           # PowerShell wrapper (tracked)
├── Setup-AnsibleWSL.ps1             # WSL setup automation (tracked)
├── credentials/
│   ├── vault_credentials_*.yml       # Encrypted ONTAP passwords (gitignored)
│   └── vault_template.yml            # Template (tracked)
└── README.md                         # This file (tracked, sanitized)
```

---

## PowerShell Wrapper — `Invoke-S3Provision.ps1`

Resolves cluster hostname, SVM, S3 user, credentials, and vault file from `config.json` (`S3_Config` section) automatically.

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-Cluster` | **Yes** | — | Cluster alias or name from `config.json` |
| `-BucketName` | **Yes** | — | S3 bucket name |
| `-Vserver` | No | from `S3_Config` | SVM name hosting the S3 server |
| `-S3User` | No | from `S3_Config` | S3 user granted access via bucket policy |
| `-CredentialName` | No | from `S3_Config` | Name of `.cred` file in `credentials/` |
| `-UseVault` | No | — | Use vault-based auth instead of direct creds |
| `-VaultFile` | No | from `S3_Config` | Vault credentials YAML path |
| `-OntapUsername` | No | `admin` | ONTAP login user |
| `-BucketSize` | No | `100GB` | Human-readable size (min ~95 GB) |
| `-DryRun` | No | — | Show command without executing |

```powershell
# Minimal — everything from config.json
.\ansible\s3-bucket-provision\Invoke-S3Provision.ps1 -Cluster <alias> -BucketName my-bucket

# Vault mode
.\ansible\s3-bucket-provision\Invoke-S3Provision.ps1 -Cluster <alias> -BucketName my-bucket -UseVault

# Custom size
.\ansible\s3-bucket-provision\Invoke-S3Provision.ps1 -Cluster <alias> -BucketName big-bucket -BucketSize 500GB

# Dry-run
.\ansible\s3-bucket-provision\Invoke-S3Provision.ps1 -Cluster <alias> -BucketName test -DryRun
```

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
