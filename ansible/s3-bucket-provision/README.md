# S3 Bucket Provisioning — svm-s3-data (cluster-s3)

Automates S3 bucket provisioning on ONTAP using the `netapp.ontap` Ansible collection.

---

## Architecture

```
cluster-s3 cluster (10.x.x.4)
└── SVM: svm-s3-data
    ├── lif_svm-s3-data_MGMT  10.x.x.5  ← REST API (management)
    │   service-policy: default-management
    │
    └── lif_svm-s3-data_287   10.x.x.14  ← S3 data endpoint
        DNS: s3-data-svm.example.local
        service-policy: sm-custom-service-policy-nas-s3
        (data-s3-server, data-nfs, data-cifs, ...)
```

**Two LIFs, two purposes:**
- **MGMT LIF** (`10.x.x.5`) — serves ONTAP REST API, System Manager, SSH. Used by Ansible.
- **S3 Data LIF** (`10.x.x.14` / `s3-data-svm.example.local`) — serves S3 protocol only. Used by S3 clients (aws-cli, rclone, app SDKs).

---

## Playbooks

| Playbook | User | Target Host | Vault File | Use Case |
|----------|------|-------------|------------|----------|
| `provision_s3_bucket_admin.yml` | `admin` | `s3-cluster` (cluster mgmt) | `vault_credentials_admin.yml` | Infrastructure admin, full cluster access |
| `provision_s3_bucket_dev.yml` | `svm_s3_dev` | `10.x.x.5` (SVM mgmt) | `vault_credentials_dev.yml` | DevOps pipeline, SVM-scoped (vsadmin role) |

Both playbooks create an S3 bucket with a bucket policy granting `sm_s3_dev` full access (Get/Put/Delete/List).

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

# Dev playbook (what DevOps team uses)
ansible-playbook provision_s3_bucket_dev.yml \
  --vault-password-file ~/.vault_pass \
  -e "bucket_name=my--bucket"

# Admin playbook (full cluster access)
ansible-playbook provision_s3_bucket_admin.yml \
  --vault-password-file ~/.vault_pass \
  -e "bucket_name=my--bucket"

# Custom size (500GB)
ansible-playbook provision_s3_bucket_dev.yml \
  --vault-password-file ~/.vault_pass \
  -e "bucket_name=my-bucket bucket_size=536870912000"

# Interactive vault password prompt (no file)
ansible-playbook provision_s3_bucket_dev.yml \
  --ask-vault-pass \
  -e "bucket_name=my-bucket"
```

### Run from Windows (PowerShell → WSL one-liner)

Since Ansible doesn't run on Windows, use these copy-paste commands from PowerShell:

```powershell
# Dev playbook (SVM user)
wsl -d Ubuntu-22.04 -- bash --norc --noprofile -c 'export PATH=/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin; cd "/mnt/c/Users/Operator/OneDrive/Documents/code/Netapp-Code-WorkSpace/ansible/s3-bucket-provision"; ansible-playbook provision_s3_bucket_dev.yml --vault-password-file ~/.vault_pass -e "bucket_name=my-bucket"'

# Admin playbook (cluster admin)
wsl -d Ubuntu-22.04 -- bash --norc --noprofile -c 'export PATH=/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin; cd "/mnt/c/Users/Operator/OneDrive/Documents/code/Netapp-Code-WorkSpace/ansible/s3-bucket-provision"; ansible-playbook provision_s3_bucket_admin.yml --vault-password-file ~/.vault_pass -e "bucket_name=my-bucket"'
```

---

## Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `bucket_name` | **Yes** | — | S3 bucket name |
| `bucket_size` | No | `107374182400` (100 GB) | Bucket size in bytes (min ~95 GB) |
| `bucket_comment` | No | `"Provisioned by Ansible DevOps automation"` | Bucket description |
| `s3_user` | No | `sm_s3_dev` | S3 user granted access via bucket policy |

---

## Credential Management

Each playbook has its own vault file (encrypted with `ansible-vault`):

| File | Contains | For Playbook |
|------|----------|-------------|
| `vault_credentials_admin.yml` | `ontap_password` for cluster `admin` | `provision_s3_bucket_admin.yml` |
| `vault_credentials_dev.yml` | `ontap_password` for SVM user `svm_s3_dev` | `provision_s3_bucket_dev.yml` |

Both vault files share the same vault unlock password (stored in `~/.vault_pass`).

### Editing vault credentials

```bash
# View (read-only)
ansible-vault view vault_credentials_dev.yml --vault-password-file ~/.vault_pass

# Decrypt → edit → re-encrypt
ansible-vault decrypt vault_credentials_dev.yml --vault-password-file ~/.vault_pass
# ... edit the file ...
ansible-vault encrypt vault_credentials_dev.yml --vault-password-file ~/.vault_pass
```

### Quick-set a  vault ONTAP password (one-liner)

Creates (or replaces) a vault file with a  ONTAP password — prompts securely, no password in shell history:

```bash
# Generic pattern:
wsl -d Ubuntu-22.04 -- bash --norc --noprofile -c 'export PATH=/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin; \
  cd "/mnt/c/Users/Operator/OneDrive/Documents/code/Netapp-Code-WorkSpace/ansible/s3-bucket-provision"; \
  ansible-vault decrypt VAULT_FILE.yml --vault-password-file ~/.vault_pass 2>/dev/null; \
  read -sp "Enter ONTAP password: " PW; echo; \
  echo "---" > VAULT_FILE.yml; \
  echo "ontap_password: \"$PW\"" >> VAULT_FILE.yml; \
  ansible-vault encrypt VAULT_FILE.yml --vault-password-file ~/.vault_pass; \
  echo "Done"'

# Example — set cluster-prod admin password:
wsl -d Ubuntu-22.04 -- bash --norc --noprofile -c 'export PATH=/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin; \
  cd "/mnt/c/Users/Operator/OneDrive/Documents/code/Netapp-Code-WorkSpace/ansible/s3-bucket-provision"; \
  ansible-vault decrypt vault_template_Prod_admin.yml --vault-password-file ~/.vault_pass 2>/dev/null; \
  read -sp "Enter cluster-prod admin password: " PW; echo; \
  echo "---" > vault_template_Prod_admin.yml; \
  echo "ontap_password: \"$PW\"" >> vault_template_Prod_admin.yml; \
  ansible-vault encrypt vault_template_Prod_admin.yml --vault-password-file ~/.vault_pass; \
  echo "Done"'
```

### Vault master password

All vault files are encrypted with a single **vault master password** — stored in:

| Store | Location | Retrieve |
|-------|----------|----------|
| WSL | `~/.vault_pass` (chmod 600) | `wsl -d Ubuntu-22.04 -- cat ~/.vault_pass` |
| PowerShell | `credentials/vault_key.cred` | `.\credentials\Get-Credential.ps1 -Name "vault_key"` |

This is NOT an ONTAP password. It's a separate key used only to lock/unlock vault files.

```bash
# View current master password
wsl -d Ubuntu-22.04 -- cat ~/.vault_pass

# Set a  master password (re-key all vault files after!)
wsl -d Ubuntu-22.04 -- bash --norc --noprofile -c 'read -sp " vault master password: " PW; echo "$PW" > ~/.vault_pass; chmod 600 ~/.vault_pass; echo "Updated"'
```

### Restore ~/.vault_pass from PowerShell credential store

If WSL is reset or `~/.vault_pass` is lost, restore from the workspace AES credential store:

```powershell
$vp = & .\credentials\Get-Credential.ps1 -Name "vault_key"
wsl -d Ubuntu-22.04 -- bash -c "echo '$vp' > ~/.vault_pass && chmod 600 ~/.vault_pass && echo 'Restored'"
```

### View a vault file using Get-Credential (no ~/.vault_pass needed)

Pull the vault master key from the PowerShell credential store and pipe it directly to `ansible-vault`:

```powershell
# Step 1: Get vault master password
$vaultPw = & .\credentials\Get-Credential.ps1 -Name "vault_key"

# Step 2: View any vault file
wsl -d Ubuntu-22.04 -- bash --norc --noprofile -c "export PATH=/usr/local/bin:/usr/bin:/bin:`$HOME/.local/bin; cd '/mnt/c/Users/Operator/OneDrive/Documents/code/Netapp-Code-WorkSpace/ansible/s3-bucket-provision'; echo '$vaultPw' | ansible-vault view credentials/vault_credentials_Prod_admin.yml --vault-password-file /dev/stdin"
```

### Pass ONTAP password from credential store directly to Ansible (no vault file needed)

```powershell
# Get ONTAP password from PowerShell credential store and pass to generic playbook
$pw = & .\credentials\Get-Credential.ps1 -Name "ontap_s3"
wsl -d Ubuntu-22.04 -- bash --norc --noprofile -c "export PATH=/usr/local/bin:/usr/bin:/bin:`$HOME/.local/bin; cd '/mnt/c/Users/Operator/OneDrive/Documents/code/Netapp-Code-WorkSpace/ansible/s3-bucket-provision'; ansible-playbook provision_s3_bucket_generic.yml -e 'ontap_hostname=cluster-prod ontap_vserver=svm_s3_prod ontap_password=$pw bucket_name=my-bucket s3_user=jfrog-s3'"
```

---

## Environment Info

| Item | Value |
|------|-------|
| Cluster | cluster-s3 (`10.x.x.4`) |
| ONTAP Version | 9.13.1P9 |
| SVM | svm-s3-data |
| SVM MGMT LIF | `10.x.x.5` (lif_svm-s3-data_MGMT) |
| S3 Data LIF | `10.x.x.14` (lif_svm-s3-data_287) |
| S3 Endpoint | `https://s3-data-svm.example.local` |
| ONTAP REST API User | `svm_s3_dev` (role: vsadmin) |
| S3 Object User | `sm_s3_dev` |
| Ansible Collection | `netapp.ontap` >= 21.19.0 |

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
net int show -vserver svm-s3-data -fields service-policy

# Fix: switch MGMT LIF to default-management
net int modify -vserver svm-s3-data -lif lif_svm-s3-data_MGMT \
  -service-policy default-management

# Verify the S3 data LIF keeps its own policy (with data-s3-server)
net int show -vserver svm-s3-data -fields service-policy
```

**Rule of thumb:** Separate your LIFs — S3 data on one LIF, management on another.
The cluster-prod cluster (`svm_s3_prod`) is a good reference: its S3 policy has NO
management services (`management-ssh`, `management-https`, `management-http`).

### "User is not authorized"

Check that:
1. The user has `http` application login: `security login show -vserver svm-s3-data -user-or-group-name svm_s3_dev`
2. The role has REST API access: `security login rest-role show -vserver svm-s3-data -role vsadmin -api /api/protocols/s3/*`
3. The password is correct (test with curl):
   ```bash
   curl -sk -u 'svm_s3_dev:PASSWORD' 'https://10.x.x.5/api/cluster?fields=version'
   ```

### Ansible doesn't run on Windows

Ansible uses POSIX blocking I/O checks that fail on Windows with:
```
OSError: [WinError 1] Incorrect function
```
Use **WSL** (Ubuntu-22.04). Ansible is installed at `~/.local/bin/`.

### WSL can't reach cluster IPs (10.x.x.x)

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
├── provision_s3_bucket_generic.yml   # Generic playbook — any cluster/SVM
├── provision_s3_bucket_admin.yml     # s3-cluster cluster admin
├── provision_s3_bucket_dev.yml       # s3-cluster SVM dev user
├── provision_s3_bucket.yml           # Legacy (original)
├── credentials/
│   ├── vault_credentials_Prod_admin.yml         # cluster-prod admin password
│   ├── vault_credentials_s3-cluster_admin.yml   # s3-cluster admin password
│   ├── vault_credentials_s3-cluster_sm_s3_dev.yml # s3-cluster svm_s3_dev password
│   ├── vault_credentials.yml                   # Legacy (shared)
│   └── vault_template.yml                      # Template (CHANGEME)
└── README.md
```
