---
name: s3-management
description: 'Manage ONTAP S3 object storage. Use when: creating S3 server, creating S3 bucket, S3 users, S3 policies, S3 access keys, SnapMirror S3, S3 snapshots, S3 auditing, FabricPool local tiering with S3, S3 multiprotocol NAS, S3 CORS, S3 object lock, S3 lifecycle, cleaning up S3 config, AWS CLI S3, bucket cleanup, delete S3 objects, rclone S3, x-amz-content-sha256, S3 replication test, bucket isolation, S3 troubleshooting.'
argument-hint: 'Specify the SVM and S3 operation (e.g., create server, create bucket, manage users)'
---

# ONTAP S3 Object Storage Management

## When to Use
- Creating or managing an S3 object store server on an ONTAP SVM
- Creating, resizing, or deleting S3 buckets
- Managing S3 users, groups, access keys, and policies
- Configuring SnapMirror S3 for bucket-level replication
- Setting up S3 for FabricPool local tiering
- Enabling S3 on multiprotocol NAS volumes (ONTAP 9.12.1+)
- Configuring S3 snapshots (ONTAP 9.16.1+)
- Auditing S3 events
- **Cleaning up S3 remnants** before SVM-DR or other operations

## Key Concepts
- **Architecture**: Each S3 bucket is backed by a FlexGroup volume (auto-created)
- **License**: S3 is zero-cost but must be installed (`system license show -package s3`)
- **Supported since**: ONTAP 9.8 (production); 9.7 was public preview only
- **Bucket limits**: min 95GB (on-prem), max = FlexGroup max (60PB), up to 1000 buckets per FlexGroup, 12000 per cluster
- **FlexGroup auto-sizing**: ONTAP 9.14.1+ auto-resizes FlexGroup as buckets are added/removed
- **Multiprotocol**: ONTAP 9.12.1+ allows S3 + NFS + SMB on same NAS volume
- **S3 protocol requires HTTPS** (best practice) with CA certificates
- **QoS**: Buckets get adaptive QoS by default (Extreme/Performance/Value) or custom policy groups
- For detailed reference, see [S3 ONTAP Reference](./references/s3-ontap-reference.md)

## Prerequisites
- S3 license installed: `system license show -package s3`
- SVM exists (or will be created)
- Aggregates with sufficient free space
- NTP configured (S3 requires ≤15 min time skew between client and cluster)
- For HTTPS: CA certificate on the SVM

## Procedures

### Create an S3 Server on an SVM

#### Option A: New SVM for S3
```powershell
# Create SVM with S3 data service
<cluster-ssh> -Command "vserver create -vserver <svm_name> -subtype default -rootvolume <root_vol> -aggregate <aggr> -rootvolume-security-style unix -language C.UTF-8 -data-services data-s3-server"

# Verify SVM
<cluster-ssh> -Command "vserver show -vserver <svm_name>"
```

#### Option B: Enable S3 on existing SVM
```powershell
# Create self-signed CA certificate
<cluster-ssh> -Command "security certificate create -vserver <svm_name> -type root-ca -common-name <ca_name>"

# Generate CSR (if using external CA)
<cluster-ssh> -Command "security certificate generate-csr -common-name <s3_server_fqdn>"

# Install signed certificate
<cluster-ssh> -Command "security certificate install -vserver <svm_name> -type server"

# Create S3 server
<cluster-ssh> -Command "vserver object-store-server create -vserver <svm_name> -object-store-server <s3_server_name> -certificate-name <cert_name> -is-http-enabled false -is-https-enabled true -https-port 443"

# Verify
<cluster-ssh> -Command "vserver object-store-server show -vserver <svm_name>"
```

### Create an S3 Bucket
```powershell
# Auto aggregate selection (default)
<cluster-ssh> -Command "vserver object-store-server bucket create -vserver <svm_name> -bucket <bucket_name> -size <size>"

# With specific aggregate (advanced privilege)
<cluster-ssh> -Command "set -privilege advanced; vserver object-store-server bucket create -vserver <svm_name> -bucket <bucket_name> -size 1TB -aggr-list <aggr1>,<aggr2>"

# For FabricPool local tiering
<cluster-ssh> -Command "vserver object-store-server bucket create -vserver <svm_name> -bucket <bucket_name> -size <size> -used-as-capacity-tier true"

# With QoS service level
<cluster-ssh> -Command "vserver object-store-server bucket create -vserver <svm_name> -bucket <bucket_name> -size <size> -storage-service-level extreme"

# Resize bucket
<cluster-ssh> -Command "vserver object-store-server bucket modify -vserver <svm_name> -bucket <bucket_name> -size <new_size>"

# Verify
<cluster-ssh> -Command "vserver object-store-server bucket show -vserver <svm_name>"
```

### Manage S3 Users

> **CRITICAL — Secret Key Capture**: The S3 secret key is shown **only once** during user creation or key regeneration. SSH non-interactive commands (`ssh admin@cluster "..."` or `-s -Command`) **swallow the secret key output**. Use the **ONTAP REST API** method below to reliably capture both access key and secret key.

#### Option A: Via REST API (Recommended — captures secret key)
```powershell
# 1. Set up REST API auth (use stored $cred or prompt)
$pair = "admin:$(<password>)"
$headers = @{Authorization = "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair)))"}

# 2. Get SVM UUID
$svm = Invoke-RestMethod -Uri "https://<cluster>/api/svm/svms?name=<svm_name>" -Headers $headers -SkipCertificateCheck
$svmUuid = $svm.records[0].uuid

# 3. Create user — response includes both access_key and secret_key
$body = @{name = "<username>"; comment = "<description>"} | ConvertTo-Json
$resp = Invoke-RestMethod -Method POST -Uri "https://<cluster>/api/protocols/s3/services/$svmUuid/users" -Headers $headers -SkipCertificateCheck -Body $body -ContentType "application/json"
$resp | ConvertTo-Json -Depth 5
# Output includes: access_key and secret_key

# 4. Regenerate keys — also returns new secret_key
Invoke-RestMethod -Method POST -Uri "https://<cluster>/api/protocols/s3/services/$svmUuid/users/<username>?regenerate_keys=true" -Headers $headers -SkipCertificateCheck -Method PATCH | ConvertTo-Json -Depth 5

# 5. Delete user
Invoke-RestMethod -Method DELETE -Uri "https://<cluster>/api/protocols/s3/services/$svmUuid/users/<username>" -Headers $headers -SkipCertificateCheck

# 6. List users
Invoke-RestMethod -Uri "https://<cluster>/api/protocols/s3/services/$svmUuid/users" -Headers $headers -SkipCertificateCheck | ConvertTo-Json -Depth 5
```

#### Option B: Via CLI (access key only — secret key is lost in non-interactive SSH)
```powershell
# Create user (generates access key + secret key — save them!)
<cluster-ssh> -Command "vserver object-store-server user create -vserver <svm_name> -user <username>"

# Create user with key expiry (ONTAP 9.14.1+)
<cluster-ssh> -Command "vserver object-store-server user create -vserver <svm_name> -user <username> -key-time-to-live P30DT0H0M0S"

# Show users (access key only, NO secret key)
<cluster-ssh> -Command "vserver object-store-server user show -vserver <svm_name>"

# Regenerate keys (secret key shown only in interactive session)
<cluster-ssh> -Command "vserver object-store-server user regenerate-keys -vserver <svm_name> -user <username>"

# Delete user
<cluster-ssh> -Command "vserver object-store-server user delete -vserver <svm_name> -user <username>"
```

> **Note**: The `-comment` parameter with spaces causes `Unexpected argument` errors via SSH. Either use the REST API or omit comments with spaces.

### Manage S3 Groups
```powershell
# Create group with policy
<cluster-ssh> -Command "vserver object-store-server group create -vserver <svm_name> -name <group_name> -users <user1>,<user2> -policies <policy_name>"

# Show groups
<cluster-ssh> -Command "vserver object-store-server group show -vserver <svm_name>"
```

### Manage S3 Policies

> **Gotchas discovered**:
> - Built-in policies (`FullAccess`, `NoS3Access`, `ReadOnlyAccess`) are **read-only** — cannot be modified. Create a custom policy instead.
> - `policy statement create` does **NOT** support `-principal` parameter — principals are assigned via **S3 groups** linking users to policies.
> - `-resource` does **NOT** accept `*/*` — use `*` for all resources, or `<bucket_name>` for specific buckets, or `<bucket_name>/prefix/...` for object paths.

```powershell
# Built-in policies: FullAccess, NoS3Access, ReadOnlyAccess (all read-only!)

# Create custom policy
<cluster-ssh> -Command "vserver object-store-server policy create -vserver <svm_name> -policy <policy_name>"

# Add policy statement (NO -principal, use groups to link users)
# For full bucket admin (create/delete/manage buckets + objects):
<cluster-ssh> -Command "vserver object-store-server policy statement create -vserver <svm_name> -policy <policy_name> -effect allow -action GetObject,PutObject,DeleteObject,ListBucket,GetBucketAcl,GetObjectAcl,ListBucketMultipartUploads,ListMultipartUploadParts,ListAllMyBuckets,CreateBucket,DeleteBucket,GetBucketLocation -resource *"

# For read-only access to a specific bucket:
<cluster-ssh> -Command "vserver object-store-server policy statement create -vserver <svm_name> -policy <policy_name> -effect allow -action GetObject,ListBucket -resource <bucket_name>"

# Show policies
<cluster-ssh> -Command "vserver object-store-server policy show -vserver <svm_name>"

# Show policy statements
<cluster-ssh> -Command "vserver object-store-server policy statement show -vserver <svm_name> -policy <policy_name>"

# Delete policy
<cluster-ssh> -Command "vserver object-store-server policy delete -vserver <svm_name> -policy <policy_name>"
```

### Bucket Access Policies
```powershell
# Add access rule to bucket
<cluster-ssh> -Command "vserver object-store-server bucket policy add-statement -vserver <svm_name> -bucket <bucket_name> -effect allow -action GetObject,PutObject,DeleteObject,ListBucket,GetBucketAcl,GetObjectAcl,ListBucketMultipartUploads,ListMultipartUploadParts -principal <user> -resource <bucket_name>,<bucket_name>/*"

# Show bucket policy
<cluster-ssh> -Command "vserver object-store-server bucket policy show -vserver <svm_name> -bucket <bucket_name>"
```

### SnapMirror S3 (Bucket-Level Replication)
**Note**: SnapMirror S3 is different from SVM-DR SnapMirror. It replicates individual buckets, not entire SVMs.

```powershell
# Prerequisites: cluster peering, SVM peering, S3 servers on both sides, root user keys

# Verify root user keys exist on both SVMs
<cluster-ssh> -Command "vserver object-store-server user show -vserver <source_svm>"
<cluster-ssh> -Command "vserver object-store-server user show -vserver <dest_svm>"

# Create SnapMirror S3 policy (or use default "Continuous")
<cluster-ssh> -Command "snapmirror policy create -vserver <svm_name> -policy <policy_name> -type continuous -rpo 3600"

# Install CA certificates cross-cluster
<cluster-ssh> -Command "security certificate install -type server-ca -vserver <admin_svm> -cert-name <dest_cert>"
<cluster-ssh> -Command "security certificate install -type server-ca -vserver <admin_svm> -cert-name <source_cert>"

# Create SnapMirror S3 relationship (note bucket path syntax)
<cluster-ssh> -Command "snapmirror create -source-path <source_svm>:/bucket/<source_bucket> -destination-path <dest_svm>:/bucket/<dest_bucket> -policy <policy_name>"

# Initialize
<cluster-ssh> -Command "snapmirror initialize -destination-path <dest_svm>:/bucket/<dest_bucket>"

# Verify
<cluster-ssh> -Command "snapmirror show -fields source-path,destination-path,state,status"
```

**SnapMirror S3 path syntax**: `svm_name:/bucket/bucket_name` (different from SVM-DR colon-only syntax!)

### S3 Snapshots (ONTAP 9.16.1+)
```powershell
# Create manual snapshot
<cluster-ssh> -Command "vserver object-store-server bucket snapshot create -vserver <svm_name> -bucket <bucket_name> -snapshot <snap_name>"

# Assign snapshot policy to bucket
<cluster-ssh> -Command "vserver object-store-server bucket modify -vserver <svm_name> -bucket <bucket_name> -snapshot-policy <policy_name>"

# Show snapshots
<cluster-ssh> -Command "vserver object-store-server bucket snapshot show -vserver <svm_name> -bucket <bucket_name>"

# Delete snapshot
<cluster-ssh> -Command "vserver object-store-server bucket snapshot delete -vserver <svm_name> -bucket <bucket_name> -snapshot <snap_name>"
```

### S3 Auditing
```powershell
# Create audit config
<cluster-ssh> -Command "vserver object-store-server audit create -vserver <svm_name> -destination <log_path>"

# Enable auditing
<cluster-ssh> -Command "vserver object-store-server audit enable -vserver <svm_name>"

# Select buckets to audit
<cluster-ssh> -Command "vserver object-store-server audit event-selector create -vserver <svm_name> -bucket <bucket_name>"

# Show audit config
<cluster-ssh> -Command "vserver object-store-server audit show -vserver <svm_name>"
```

### Enable SVM Management Access on S3 LIF
When DevOps or external users need to manage the SVM (SSH/HTTPS/ONTAPI) via the same LIF IP used for S3 data, add management services to the LIF service policy.

> **Gotcha**: `network interface service-policy add-service` requires **advanced privilege** (`set adv -c off`). At admin privilege level it returns `"add-service" is not a recognized command`.
> Also, `net int` abbreviation causes `Ambiguous argument` — always use full `network interface` command.

```powershell
# Check current service policy
<cluster-ssh> -Command "network interface service-policy show -vserver <svm_name> -policy <policy_name>"

# Add management services (requires advanced privilege)
<cluster-ssh> -Command "set adv -c off; network interface service-policy add-service -vserver <svm_name> -policy <policy_name> -service management-ssh"
<cluster-ssh> -Command "set adv -c off; network interface service-policy add-service -vserver <svm_name> -policy <policy_name> -service management-https"
<cluster-ssh> -Command "set adv -c off; network interface service-policy add-service -vserver <svm_name> -policy <policy_name> -service management-http"

# Verify
<cluster-ssh> -Command "network interface service-policy show -vserver <svm_name> -policy <policy_name>"
```

### Create Vserver Login for SVM Management
Create a dedicated vserver-level login so DevOps can manage the SVM via SSH/HTTP/ONTAPI without using the default `vsadmin`.

```powershell
# Create SSH login (will prompt for password)
<cluster-ssh> -Command "security login create -vserver <svm_name> -user-or-group-name <username> -application ssh -authentication-method password -role vsadmin"

# Create HTTP login (reuses same password)
<cluster-ssh> -Command "security login create -vserver <svm_name> -user-or-group-name <username> -application http -authentication-method password -role vsadmin"

# Create ONTAPI login (reuses same password)
<cluster-ssh> -Command "security login create -vserver <svm_name> -user-or-group-name <username> -application ontapi -authentication-method password -role vsadmin"

# Verify
<cluster-ssh> -Command "security login show -vserver <svm_name>"
```

### Full Workflow: Create DevOps S3 User with Bucket Auto-Provisioning
Complete end-to-end procedure for giving DevOps automated S3 bucket management:

```powershell
# 1. Add management services to LIF service policy (advanced priv)
<cluster-ssh> -Command "set adv -c off; network interface service-policy add-service -vserver <svm_name> -policy <service_policy> -service management-ssh"
<cluster-ssh> -Command "set adv -c off; network interface service-policy add-service -vserver <svm_name> -policy <service_policy> -service management-https"
<cluster-ssh> -Command "set adv -c off; network interface service-policy add-service -vserver <svm_name> -policy <service_policy> -service management-http"

# 2. Create S3 user via REST API (to capture secret key)
$body = @{name = "<s3_username>"; comment = "<description>"} | ConvertTo-Json
$resp = Invoke-RestMethod -Method POST -Uri "https://<cluster>/api/protocols/s3/services/$svmUuid/users" -Headers $headers -SkipCertificateCheck -Body $body -ContentType "application/json"
# SAVE: $resp.records[0].access_key and $resp.records[0].secret_key

# 3. Create custom S3 policy
<cluster-ssh> -Command "vserver object-store-server policy create -vserver <svm_name> -policy <policy_name>"
<cluster-ssh> -Command "vserver object-store-server policy statement create -vserver <svm_name> -policy <policy_name> -effect allow -action GetObject,PutObject,DeleteObject,ListBucket,GetBucketAcl,GetObjectAcl,ListBucketMultipartUploads,ListMultipartUploadParts,ListAllMyBuckets,CreateBucket,DeleteBucket,GetBucketLocation -resource *"

# 4. Create S3 group (links user to policy)
<cluster-ssh> -Command "vserver object-store-server group create -vserver <svm_name> -name <group_name> -users <s3_username> -policies <policy_name>"

# 5. Create vserver login for SVM management
<cluster-ssh> -Command "security login create -vserver <svm_name> -user-or-group-name <login_username> -application ssh -authentication-method password -role vsadmin"
<cluster-ssh> -Command "security login create -vserver <svm_name> -user-or-group-name <login_username> -application http -authentication-method password -role vsadmin"
<cluster-ssh> -Command "security login create -vserver <svm_name> -user-or-group-name <login_username> -application ontapi -authentication-method password -role vsadmin"

# 6. Verify everything
<cluster-ssh> -Command "vserver object-store-server user show -vserver <svm_name>"
<cluster-ssh> -Command "vserver object-store-server group show -vserver <svm_name> -instance"
<cluster-ssh> -Command "vserver object-store-server policy statement show -vserver <svm_name> -policy <policy_name>"
<cluster-ssh> -Command "security login show -vserver <svm_name>"
<cluster-ssh> -Command "network interface service-policy show -vserver <svm_name> -policy <service_policy>"
```

## S3 Cleanup (Before SVM-DR or Decommission)

**CRITICAL**: S3 remnants (users, policies, buckets, server) block SVM-DR creation. Always clean up in this order:

```powershell
# 1. Check what exists
<cluster-ssh> -Command "vserver object-store-server show -vserver <svm_name>"
<cluster-ssh> -Command "vserver object-store-server bucket show -vserver <svm_name>"
<cluster-ssh> -Command "vserver object-store-server user show -vserver <svm_name>"
<cluster-ssh> -Command "vserver object-store-server policy show -vserver <svm_name>"

# 2. Delete in order: buckets → users → policies → server
<cluster-ssh> -Command "vserver object-store-server bucket delete -vserver <svm_name> -bucket <bucket_name>"
<cluster-ssh> -Command "vserver object-store-server user delete -vserver <svm_name> -user <username>"
<cluster-ssh> -Command "vserver object-store-server policy delete -vserver <svm_name> -policy <policy_name>"
<cluster-ssh> -Command "vserver object-store-server delete -vserver <svm_name>"
```

**Error if S3 remnants exist during SVM-DR**: `"contains either an object store server, object store policy, object store user or object store bucket"`

## Troubleshooting

| Error / Issue | Cause | Fix |
|---------------|-------|-----|
| S3 blocks SVM-DR creation | Leftover S3 config on source SVM | Delete S3 objects in order (see cleanup section) |
| Client access denied | Missing/expired access keys | Regenerate keys, update client config |
| Certificate error on HTTPS | CA cert not installed or expired | Install/renew CA certificate on SVM |
| Bucket creation fails | No aggregates with sufficient space | Add disks or use different aggregate |
| Time skew error | NTP not configured or >15 min difference | Configure NTP on cluster |
| Secret key not captured | SSH non-interactive swallows `create`/`regenerate-keys` output | Use ONTAP REST API (`POST /api/protocols/s3/services/{uuid}/users`) — response JSON includes both `access_key` and `secret_key` |
| `"add-service" is not a recognized command` | `service-policy add-service` requires advanced privilege | Prefix with `set adv -c off;` |
| `Ambiguous argument` on `net int` | `net` abbreviation matches multiple commands | Use full command: `network interface ...` |
| `invalid argument "-principal"` on policy statement | `-principal` not supported on `policy statement create` | Assign users to policies via S3 **groups** instead |
| `The value "*/*" is not valid for field "-resource"` | Resource syntax doesn't accept `*/*` | Use `*` for all, or `<bucket_name>` for specific bucket, or `<bucket_name>/path/...` for object paths |
| `Unexpected argument` with `-comment` via SSH | Spaces in comment break SSH command quoting | Use REST API for comments with spaces, or omit comment |
| `x-amz-content-sha256 must be UNSIGNED-PAYLOAD...` on AWS CLI upload | AWS CLI v2+ sends content-sha256 header that ONTAP rejects | Set env vars: `AWS_REQUEST_CHECKSUM_CALCULATION=WHEN_REQUIRED` and `AWS_RESPONSE_CHECKSUM_VALIDATION=WHEN_REQUIRED` before running `aws s3 cp` / `aws s3 sync`. List/download work without this. Confirmed on ONTAP 9.13.1P9. |
| `400 Bad Request for url: /api/cluster?fields=version` via Ansible | `data-s3-server` in the SVM mgmt LIF service policy hijacks port 443 — S3 protocol responds with XML instead of REST API JSON | Move mgmt LIF to `default-management` policy: `net int modify -vserver <svm> -lif <mgmt_lif> -service-policy default-management`. Keep S3 data on a separate LIF. |
| `User is not authorized` via Ansible on cluster mgmt LIF | SVM-scoped user (e.g. `svm_s3_dev`) accessing cluster mgmt LIF — `vsadmin` role may lack REST access | Verify `security login rest-role show -vserver <svm> -role vsadmin -api /api/protocols/s3/*`. Use SVM mgmt LIF with `default-management` instead. |
| Ansible `OSError: [WinError 1] Incorrect function` | Ansible doesn't support Windows as control node — `check_blocking_io()` uses POSIX-only `os.get_blocking()` | Use WSL: `wsl -d Ubuntu-22.04` |
| WSL can't reach cluster IPs (10.x.x.x) | WSL2 NAT can't route to corporate subnets | Add `[wsl2]\nnnetworkingMode=mirrored` to `C:\Users\<you>\.wslconfig`, then `wsl --shutdown` |

## Ansible Automation — S3 Bucket Provisioning

Playbooks at `ansible/s3-bucket-provision/` for automated S3 bucket provisioning.

### Playbooks

| Playbook | Purpose | Credentials |
|----------|---------|-------------|
| `provision_s3_bucket_generic.yml` | **Any cluster/SVM** — fully parameterized | Via `-e @vault_file` or `-e ontap_password=...` |
| `provision_s3_bucket_admin.yml` | <cluster-name> cluster admin | `credentials/vault_credentials_<cluster-name>_admin.yml` |
| `provision_s3_bucket_dev.yml` | <cluster-name> SVM dev user | `credentials/vault_credentials_<cluster-name>_sm_s3_dev.yml` |

### Prerequisites
```bash
pip install ansible netapp-lib
ansible-galaxy collection install netapp.ontap
```

> **Windows**: Ansible doesn't run natively (OSError: check_blocking_io). Use **WSL** (`wsl -d Ubuntu-22.04`).

### Generic Playbook Usage (any cluster)

```powershell
# With vault file (vault password in ~/.vault_pass)
wsl -d Ubuntu-22.04 -- bash --norc --noprofile -c 'export PATH=/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin; cd "<workspace-root>/ansible/s3-bucket-provision"; ansible-playbook provision_s3_bucket_generic.yml -e @credentials/vault_credentials_<cluster>_admin.yml --vault-password-file ~/.vault_pass -e "ontap_hostname=<cluster-name> ontap_vserver=<s3-svm> bucket_name=my-bucket bucket_size=200GB s3_user=<s3-user>"'

# With Get-Credential (no vault file needed)
$pw = & .\credentials\Get-Credential.ps1 -Name "admin_<cluster-name>"
wsl -d Ubuntu-22.04 -- bash --norc --noprofile -c "export PATH=/usr/local/bin:/usr/bin:/bin:`$HOME/.local/bin; cd '<workspace-root>/ansible/s3-bucket-provision'; ansible-playbook provision_s3_bucket_generic.yml -e 'ontap_hostname=<cluster-name> ontap_vserver=<s3-svm> ontap_password=$pw bucket_name=my-bucket bucket_size=200GB s3_user=<s3-user>'"
```

### Required Parameters (generic playbook)

| Parameter | Description | Example |
|-----------|-------------|---------|
| `ontap_hostname` | Cluster or SVM mgmt LIF | `<cluster-name>`, `<cluster-name>`, `<cluster-ip>` |
| `ontap_vserver` | SVM name | `<s3-svm>`, `<s3-svm>` |
| `ontap_password` | ONTAP REST API password | via vault file or `-e` |
| `bucket_name` | Bucket name | `devops-artifacts` |
| `s3_user` | S3 object store user for bucket policy | `<s3-user>`, `sm_s3_dev` |
| `bucket_size` | Size (human-readable, default 100GB) | `200GB`, `1TB` |

### Credential Management

#### Vault files (ansible-vault encrypted)
```
credentials/
├── vault_credentials_<cluster>_admin.yml         # <cluster-name> admin
├── vault_credentials_<cluster-name>_admin.yml   # <cluster-name> admin
├── vault_credentials_<cluster-name>_sm_s3_dev.yml # <cluster-name> SVM user
└── vault_template.yml                      # Template
```

All vault files encrypted with a single **vault master password** stored in:
- WSL: `~/.vault_pass` (chmod 600)
- PowerShell: `.\credentials\Get-Credential.ps1 -Name "vault_key"`

The vault master password is NOT an ONTAP password — it's a separate key.

#### Quick-set a vault ONTAP password
```bash
wsl -d Ubuntu-22.04 -- bash --norc --noprofile -c 'export PATH=/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin; \
  cd "<workspace-root>/ansible/s3-bucket-provision"; \
  ansible-vault decrypt VAULT_FILE.yml --vault-password-file ~/.vault_pass 2>/dev/null; \
  read -sp "Enter ONTAP password: " PW; echo; \
  echo "---" > VAULT_FILE.yml; echo "ontap_password: \"$PW\"" >> VAULT_FILE.yml; \
  ansible-vault encrypt VAULT_FILE.yml --vault-password-file ~/.vault_pass; echo "Done"'
```

#### View vault via Get-Credential (no ~/.vault_pass needed)
```powershell
$vaultPw = & .\credentials\Get-Credential.ps1 -Name "vault_key"
wsl -d Ubuntu-22.04 -- bash --norc --noprofile -c "export PATH=/usr/local/bin:/usr/bin:/bin:`$HOME/.local/bin; cd '<workspace-root>/ansible/s3-bucket-provision'; echo '$vaultPw' | ansible-vault view credentials/vault_credentials_<cluster>_admin.yml --vault-password-file /dev/stdin"
```

### Key Lessons Learned

#### SVM LIF Service Policy — S3 hijacks port 443
If `data-s3-server` is in the same service policy as `management-https`, S3 takes over port 443. REST API calls to that LIF return S3 XML instead of JSON → `400 Bad Request`.

**Fix:** Separate LIFs — S3 data on one LIF, management on another:
```
net int modify -vserver <svm> -lif <mgmt_lif> -service-policy default-management
```

Reference: <cluster-name>'s `<s3-svm>` does this correctly — S3 policy has NO management services.

#### ONTAP admin user vs S3 object store user
- **ONTAP admin** (`admin`, `svm_s3_dev`): authenticates via REST API to create/manage buckets
- **S3 object store user** (`<s3-user>`, `sm_s3_dev`): referenced by name in bucket policies, authenticates via access key + secret key from S3 clients

The playbook uses ONTAP admin credentials and only writes the S3 username into the bucket policy. No S3 access keys are needed.

#### WSL networking
WSL2 NAT can't reach corporate subnets (10.x.x.x). Fix: `C:\Users\<you>\.wslconfig` with `[wsl2]\nnnetworkingMode=mirrored`, then `wsl --shutdown`.

### Collection Modules Used
| Module | Purpose |
|--------|---------|
| `netapp.ontap.na_ontap_s3_buckets` | Create/delete/modify S3 buckets with inline bucket policies |
| `netapp.ontap.na_ontap_s3_users` | Create/delete S3 users (returns `access_key` + `secret_key` on creation) |
| `netapp.ontap.na_ontap_s3_services` | Create/modify S3 server config |
| `netapp.ontap.na_ontap_s3_groups` | Create S3 groups linking users to policies |
| `netapp.ontap.na_ontap_s3_policies` | Create S3 access policies |

### Key Design Decisions
- Uses `module_defaults` with `group/netapp.ontap.netapp_ontap` to set connection params once
- All modules use **REST API only** (`use_rest: always`) — ZAPI is deprecated
- `validate_certs: false` because clusters use self-signed certificates
- Generic playbook accepts human-readable sizes (`100GB`, `1TB`) via Ansible `human_to_bytes` filter
- Bucket policy is inline — grants the specified `s3_user` full object access on creation
- Playbook is **idempotent** — re-running won't duplicate buckets
- `na_ontap_s3_users` returns `access_key` and `secret_key` as return values when creating a user

## References
- [S3 ONTAP Detailed Reference](./references/s3-ontap-reference.md)
- [S3 Client Operations — AWS CLI, Scripts & Troubleshooting](./references/s3-client-operations.md)
- [Ansible Playbook — S3 Bucket Provisioning](../../ansible/s3-bucket-provision/)
- [S3 PowerShell Scripts Library](<path-to-s3-scripts>/)
- [na_ontap_s3_buckets module](https://docs.ansible.com/ansible/latest/collections/netapp/ontap/na_ontap_s3_buckets_module.html)
- [na_ontap_s3_users module](https://docs.ansible.com/ansible/latest/collections/netapp/ontap/na_ontap_s3_users_module.html)
- [na_ontap_s3_services module](https://docs.ansible.com/ansible/latest/collections/netapp/ontap/na_ontap_s3_services_module.html)
