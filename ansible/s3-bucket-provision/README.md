# S3 Bucket Provisioning — <s3-svm> (<cluster-name>)

Automates S3 bucket provisioning on ONTAP using the `netapp.ontap` Ansible collection.

---

## Architecture

```
<cluster-name> cluster (<cluster-mgmt-ip>)
└── SVM: <s3-svm>
    ├── lif_<s3-svm>_MGMT  <cluster-ip>  ← REST API (management)
    │   service-policy: default-management
    │
    └── lif_<s3-svm>_287   <s3-data-lif-ip>  ← S3 data endpoint
        DNS: <s3-data-lif-fqdn>
        service-policy: sm-custom-service-policy-nas-s3
        (data-s3-server, data-nfs, data-cifs, ...)
```

**Two LIFs, two purposes:**
- **MGMT LIF** (`<cluster-ip>`) — serves ONTAP REST API, System Manager, SSH. Used by Ansible.
- **S3 Data LIF** (`<s3-data-lif-ip>` / `<s3-data-lif-fqdn>`) — serves S3 protocol only. Used by S3 clients (aws-cli, rclone, app SDKs).

---

## Playbooks

| Playbook | User | Target Host | Vault File | Use Case |
|----------|------|-------------|------------|----------|
| `provision_s3_bucket_admin.yml` | `admin` | `<cluster-name>` (cluster mgmt) | `vault_credentials_admin.yml` | Infrastructure admin, full cluster access |
| `provision_s3_bucket_dev.yml` | `svm_s3_dev` | `<cluster-ip>` (SVM mgmt) | `vault_credentials_dev.yml` | DevOps pipeline, SVM-scoped (vsadmin role) |

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
  -e "bucket_name=my-new-bucket"

# Admin playbook (full cluster access)
ansible-playbook provision_s3_bucket_admin.yml \
  --vault-password-file ~/.vault_pass \
  -e "bucket_name=my-new-bucket"

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
wsl -d Ubuntu-22.04 -- bash --norc --noprofile -c 'export PATH=/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin; cd "<workspace-root>/ansible/s3-bucket-provision"; ansible-playbook provision_s3_bucket_dev.yml --vault-password-file ~/.vault_pass -e "bucket_name=my-bucket"'

# Admin playbook (cluster admin)
wsl -d Ubuntu-22.04 -- bash --norc --noprofile -c 'export PATH=/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin; cd "<workspace-root>/ansible/s3-bucket-provision"; ansible-playbook provision_s3_bucket_admin.yml --vault-password-file ~/.vault_pass -e "bucket_name=my-bucket"'
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

### Quick-set a new vault ONTAP password (one-liner)

Creates (or replaces) a vault file with a new ONTAP password — prompts securely, no password in shell history:

```bash
# Generic pattern:
wsl -d Ubuntu-22.04 -- bash --norc --noprofile -c 'export PATH=/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin; \
  cd "<workspace-root>/ansible/s3-bucket-provision"; \
  ansible-vault decrypt VAULT_FILE.yml --vault-password-file ~/.vault_pass 2>/dev/null; \
  read -sp "Enter ONTAP password: " PW; echo; \
  echo "---" > VAULT_FILE.yml; \
  echo "ontap_password: \"$PW\"" >> VAULT_FILE.yml; \
  ansible-vault encrypt VAULT_FILE.yml --vault-password-file ~/.vault_pass; \
  echo "Done"'

# Example — set <cluster-name> admin password:
wsl -d Ubuntu-22.04 -- bash --norc --noprofile -c 'export PATH=/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin; \
  cd "<workspace-root>/ansible/s3-bucket-provision"; \
  ansible-vault decrypt vault_template_a1k_admin.yml --vault-password-file ~/.vault_pass 2>/dev/null; \
  read -sp "Enter <cluster-name> admin password: " PW; echo; \
  echo "---" > vault_template_a1k_admin.yml; \
  echo "ontap_password: \"$PW\"" >> vault_template_a1k_admin.yml; \
  ansible-vault encrypt vault_template_a1k_admin.yml --vault-password-file ~/.vault_pass; \
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

# Set a new master password (re-key all vault files after!)
wsl -d Ubuntu-22.04 -- bash --norc --noprofile -c 'read -sp "New vault master password: " PW; echo "$PW" > ~/.vault_pass; chmod 600 ~/.vault_pass; echo "Updated"'
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
wsl -d Ubuntu-22.04 -- bash --norc --noprofile -c "export PATH=/usr/local/bin:/usr/bin:/bin:`$HOME/.local/bin; cd '<workspace-root>/ansible/s3-bucket-provision'; echo '$vaultPw' | ansible-vault view credentials/vault_credentials_a1k_admin.yml --vault-password-file /dev/stdin"
```

### Pass ONTAP password from credential store directly to Ansible (no vault file needed)

```powershell
# Get ONTAP password from PowerShell credential store and pass to generic playbook
$pw = & .\credentials\Get-Credential.ps1 -Name "ontap_s3"
wsl -d Ubuntu-22.04 -- bash --norc --noprofile -c "export PATH=/usr/local/bin:/usr/bin:/bin:`$HOME/.local/bin; cd '<workspace-root>/ansible/s3-bucket-provision'; ansible-playbook provision_s3_bucket_generic.yml -e 'ontap_hostname=<cluster-name> ontap_vserver=<s3-svm> ontap_password=$pw bucket_name=my-bucket s3_user=jfrog-s3'"
```

---

## Environment Info

| Item | Value |
|------|-------|
| Cluster | <cluster-name> (`<cluster-mgmt-ip>`) |
| ONTAP Version | 9.13.1P9 |
| SVM | <s3-svm> |
| SVM MGMT LIF | `<cluster-ip>` (lif_<s3-svm>_MGMT) |
| S3 Data LIF | `<s3-data-lif-ip>` (lif_<s3-svm>_287) |
| S3 Endpoint | `https://<s3-data-lif-fqdn>` |
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
net int show -vserver <s3-svm> -fields service-policy

# Fix: switch MGMT LIF to default-management
net int modify -vserver <s3-svm> -lif lif_<s3-svm>_MGMT \
  -service-policy default-management

# Verify the S3 data LIF keeps its own policy (with data-s3-server)
net int show -vserver <s3-svm> -fields service-policy
```

**Rule of thumb:** Separate your LIFs — S3 data on one LIF, management on another.
The <cluster-name> cluster (`<s3-svm>`) is a good reference: its S3 policy has NO
management services (`management-ssh`, `management-https`, `management-http`).

### "User is not authorized"

Check that:
1. The user has `http` application login: `security login show -vserver <s3-svm> -user-or-group-name svm_s3_dev`
2. The role has REST API access: `security login rest-role show -vserver <s3-svm> -role vsadmin -api /api/protocols/s3/*`
3. The password is correct (test with curl):
   ```bash
   curl -sk -u 'svm_s3_dev:PASSWORD' 'https://<cluster-ip>/api/cluster?fields=version'
   ```

### Ansible doesn't run on Windows

Ansible uses POSIX blocking I/O checks that fail on Windows with:
```
OSError: [WinError 1] Incorrect function
```
Use **WSL** (Ubuntu-22.04). Ansible is installed at `~/.local/bin/`.

### WSL can't reach cluster IPs (10.163.x.x)

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
├── provision_s3_bucket_admin.yml     # <cluster-name> cluster admin
├── provision_s3_bucket_dev.yml       # <cluster-name> SVM dev user
├── provision_s3_bucket.yml           # Legacy (original)
├── credentials/
│   ├── vault_credentials_a1k_admin.yml         # <cluster-name> admin password
│   ├── vault_credentials_<cluster-name>_admin.yml   # <cluster-name> admin password
│   ├── vault_credentials_<cluster-name>_sm_s3_dev.yml # <cluster-name> svm_s3_dev password
│   ├── vault_credentials.yml                   # Legacy (shared)
│   └── vault_template.yml                      # Template (CHANGEME)
└── README.md
```
