# S3 Object Storage Reference — From ONTAP 9 S3 Object Storage Management PDF

## ONTAP S3 Architecture

- Each S3 bucket is backed by a **FlexGroup volume** (automatically created)
- S3 protocol access via authorized users and client applications
- Since ONTAP 9.12.1: S3 can coexist on **multiprotocol NAS volumes** (NFS + SMB + S3)
- S3 server requires an SVM — can be dedicated S3 SVM or shared with NAS/SAN

## Version Support

| Feature | ONTAP Version |
|---------|--------------|
| S3 (production) | 9.8+ |
| Object metadata & tagging | 9.9.1+ |
| Object versioning | 9.11.1+ |
| Object Lock | 9.14.1+ (requires SnapLock license) |
| Bucket lifecycle management | 9.13.1+ (expiration only) |
| S3 multiprotocol NAS | 9.12.1+ |
| FlexGroup auto-sizing | 9.14.1+ |
| S3 on MetroCluster (mirrored) | 9.14.1+ |
| S3 on MetroCluster (unmirrored) | 9.12.1+ (IP only) |
| LDAP/AD integration for S3 | 9.14.1+ |
| Key time-to-live (expiry) | 9.14.1+ |
| S3 snapshots | 9.16.1+ |
| CopyObject | 9.12.1+ |
| DeleteObjects (multi) | 9.11.1+ |
| SnapMirror S3 | 9.10.1+ |

## Bucket Limits

| Parameter | Limit |
|-----------|-------|
| Minimum capacity (on-prem) | 95 GB |
| Minimum capacity (ONTAP Select) | 200 MB |
| Maximum capacity | FlexGroup max (60 PB) |
| Max buckets per FlexGroup | 1,000 |
| Max buckets per cluster | 12,000 (12 FlexGroups) |
| Max S3 snapshots per bucket | 1,023 |

## FlexGroup Sizing

### ONTAP 9.14.1+ (Auto-sizing)
- FlexGroup auto-grows/shrinks based on total bucket sizes
- Example: 3 buckets of 100GB + 300GB + 500GB → FlexGroup = 900GB

### ONTAP 9.13.1 and earlier (Fixed)
- Default: 1.6 PB (ONTAP), 100 TB (ONTAP Select)
- If insufficient space, halved until fits
- Rule: total used capacity < 33% of FlexGroup max capacity

## S3 Server Configuration

### CLI Commands
```
# Check S3 license
system license show -package s3

# Create S3 server
vserver object-store-server create -vserver <svm> -object-store-server <name> -certificate-name <cert> -is-http-enabled false -is-https-enabled true -https-port 443

# Show S3 server
vserver object-store-server show [-instance]

# Modify S3 server
vserver object-store-server modify -vserver <svm> ...

# Delete S3 server
vserver object-store-server delete -vserver <svm>
```

### Certificate Setup
```
# Self-signed root CA
security certificate create -vserver <svm> -type root-ca -common-name <ca_name>

# Generate CSR for external CA
security certificate generate-csr -common-name <s3_fqdn>

# Install signed certificate
security certificate install -vserver <svm> -type server

# Install remote server CA (for SnapMirror S3)
security certificate install -type server-ca -vserver <admin_svm> -cert-name <cert>
```

## Bucket Operations

### Create
```
# Auto aggregate selection
vserver object-store-server bucket create -vserver <svm> -bucket <name> -size <size>

# With service level
vserver object-store-server bucket create -vserver <svm> -bucket <name> -size <size> -storage-service-level {value|performance|extreme}

# For FabricPool tiering
vserver object-store-server bucket create -vserver <svm> -bucket <name> -size <size> -used-as-capacity-tier true

# Manual aggregate selection (advanced privilege)
set -privilege advanced
vserver object-store-server bucket create -vserver <svm> -bucket <name> -size 1TB -aggr-list <aggr1>,<aggr2> -aggr-list-multiplier 4

# With versioning (ONTAP 9.11.1+)
vserver object-store-server bucket create -vserver <svm> -bucket <name> -size <size> -versioning-state enabled

# With Object Lock (ONTAP 9.14.1+, requires SnapLock license)
vserver object-store-server bucket create -vserver <svm> -bucket <name> -size <size> -object-lock-enabled true
```

### Modify / Resize
```
vserver object-store-server bucket modify -vserver <svm> -bucket <name> -size <new_size>
vserver object-store-server bucket modify -vserver <svm> -bucket <name> -qos-policy-group <qos_group>
```

### Show / Delete
```
vserver object-store-server bucket show [-instance]
vserver object-store-server bucket delete -vserver <svm> -bucket <name>
```

## User Management

```
# Create user (SAVE the access key and secret key!)
vserver object-store-server user create -vserver <svm> -user <name>

# With key expiry (ONTAP 9.14.1+)
vserver object-store-server user create -vserver <svm> -user <name> -key-time-to-live P30DT0H0M0S

# Show users
vserver object-store-server user show -vserver <svm>

# Regenerate keys
vserver object-store-server user regenerate-keys -vserver <svm> -user <name>

# Delete user
vserver object-store-server user delete -vserver <svm> -user <name>
```

## Group Management

```
# Create group with users and policies
vserver object-store-server group create -vserver <svm> -name <group> -users <user1>,<user2> -policies <policy>

# Show groups
vserver object-store-server group show -vserver <svm>

# Modify group
vserver object-store-server group modify -vserver <svm> -name <group> -users <user1>,<user2> -policies <new_policy>

# Delete group
vserver object-store-server group delete -vserver <svm> -name <group>
```

## Policies

### Built-in Policies
| Policy | Description |
|--------|-------------|
| FullAccess | Full access to all buckets |
| NoS3Access | No S3 access |
| ReadOnlyAccess | Read-only access |

### Custom Policy Commands
```
# Create policy
vserver object-store-server policy create -vserver <svm> -policy <name>

# Add statement
vserver object-store-server policy statement create -vserver <svm> -policy <name> -effect {allow|deny} -action <actions> -principal <users_or_groups> -resource <bucket>,<bucket>/*

# Available actions:
# GetObject, PutObject, DeleteObject, ListBucket, GetBucketAcl,
# GetObjectAcl, ListAllMyBuckets, ListBucketMultipartUploads,
# ListMultipartUploadParts, GetObjectTagging, PutObjectTagging,
# DeleteObjectTagging, GetBucketVersioning, PutBucketVersioning

# Show/delete
vserver object-store-server policy show -vserver <svm>
vserver object-store-server policy delete -vserver <svm> -policy <name>
```

### Bucket Policies
```
# Add bucket-level access
vserver object-store-server bucket policy add-statement -vserver <svm> -bucket <name> -effect allow -action <actions> -principal <user> -resource <bucket>,<bucket>/*

# Show bucket policy
vserver object-store-server bucket policy show -vserver <svm> -bucket <name>

# With variables (ONTAP 9.14.1+)
vserver object-store-server bucket policy statement create -vserver <svm> -bucket <name> -effect allow -action * -principal - -resource <bucket>,<bucket>/${aws:username}/*
```

## SnapMirror S3

### Key Differences from SVM-DR SnapMirror
| Aspect | SnapMirror S3 | SVM-DR SnapMirror |
|--------|--------------|-------------------|
| Scope | Individual buckets | Entire SVM |
| Path syntax | `svm:/bucket/bucket_name` | `svm_name:` |
| Policy type | `continuous` | `async-mirror` or `mirror-vault` |
| Default policy | `Continuous` (RPO 1h) | `MirrorAndVault` |
| Destinations | ONTAP, StorageGRID, AWS S3, CVO | ONTAP only |
| Since | ONTAP 9.10.1 | ONTAP 9.5 |
| MetroCluster | Not supported | Supported |

### Requirements
- ONTAP 9.10.1+ on both clusters
- S3 servers running on both source and destination SVMs
- **Root user access keys** must exist on both SVMs
- CA certificates installed cross-cluster
- Cluster and SVM peering (for remote ONTAP targets)

### Supported Targets
| Target | Active Mirror + Takeover | Backup + Restore |
|--------|-------------------------|-------------------|
| ONTAP S3 (same/different cluster) | Yes | Yes |
| StorageGRID | No | Yes |
| AWS S3 | No | Yes |
| Cloud Volumes ONTAP | Yes | Yes |

### Workflow
```
# 1. Verify root user keys
vserver object-store-server user show

# 2. Create buckets on both source and destination
vserver object-store-server bucket create ...

# 3. Add bucket policies
vserver object-store-server bucket policy add-statement ...

# 4. Create SnapMirror S3 policy (optional — default is Continuous)
snapmirror policy create -vserver <svm> -policy <name> -type continuous -rpo 3600

# 5. Install CA certificates cross-cluster
security certificate install -type server-ca -vserver <admin_svm> -cert-name <cert>

# 6. Create relationship
snapmirror create -source-path <src_svm>:/bucket/<src_bucket> -destination-path <dst_svm>:/bucket/<dst_bucket> -policy <policy>

# 7. Initialize
snapmirror initialize -destination-path <dst_svm>:/bucket/<dst_bucket>
```

### Limitations
- No fan-in (multiple sources → one destination bucket)
- Fan-out and cascade are supported
- Not supported in MetroCluster
- Does NOT replicate users, groups, or policies — configure separately on destination

## S3 Snapshots (ONTAP 9.16.1+)

- Read-only point-in-time images of S3 buckets
- Presented as S3 buckets to clients: `<bucket_name>-s3snap-<snapshot_name>`
- Manual or policy-driven creation
- Max 1023 snapshots per bucket
- Only captures current object versions (not historical versions on versioned buckets)

### Commands
```
# Create snapshot
vserver object-store-server bucket snapshot create -vserver <svm> -bucket <name> -snapshot <snap_name>

# Assign snapshot policy
vserver object-store-server bucket modify -vserver <svm> -bucket <name> -snapshot-policy <policy>

# Show snapshots
vserver object-store-server bucket snapshot show -vserver <svm> -bucket <name>

# Delete snapshot
vserver object-store-server bucket snapshot delete -vserver <svm> -bucket <name> -snapshot <snap_name>

# Restore (copy from snapshot bucket via S3 client — ONTAP doesn't have a CLI restore command)
```

### Limitations
- Not supported on: SnapMirror S3 buckets, Object Lock buckets, MetroCluster
- Not recommended on FabricPool capacity tier buckets
- Snapshot names: max 30 chars, lowercase + numbers + dots + hyphens

## S3 Auditing

Tracks GetObject, PutObject, DeleteObject events per bucket.

```
# Create audit config
vserver object-store-server audit create -vserver <svm> -destination <path>

# Enable
vserver object-store-server audit enable -vserver <svm>

# Add bucket to audit
vserver object-store-server audit event-selector create -vserver <svm> -bucket <name>

# Show
vserver object-store-server audit show -vserver <svm>
vserver object-store-server audit event-selector show -vserver <svm>

# Modify
vserver object-store-server audit modify -vserver <svm> ...

# Disable
vserver object-store-server audit disable -vserver <svm>
```

## S3 + SVM-DR Interaction

**CRITICAL**: S3 configurations on a source SVM will block SVM-DR (SnapMirror identity-preserve) creation.

Error: `"contains either an object store server, object store policy, object store user or object store bucket"`

### Cleanup Order (must delete in this sequence)
1. Buckets: `vserver object-store-server bucket delete`
2. Users: `vserver object-store-server user delete`
3. Policies: `vserver object-store-server policy delete`
4. Server: `vserver object-store-server delete`

### Discovery Commands
```
vserver object-store-server show -vserver <svm>
vserver object-store-server bucket show -vserver <svm>
vserver object-store-server user show -vserver <svm>
vserver object-store-server policy show -vserver <svm>
```

## QoS / Performance Service Levels

| Service Level | Use Case |
|---------------|----------|
| Extreme | Lowest latency, highest performance (default on AFF) |
| Performance | Moderate performance needs |
| Value | Throughput/capacity over latency |
| Custom | User-defined QoS policy group |
| Tiering | Low-cost media, optimal for FabricPool |

## LDAP/AD Integration (ONTAP 9.14.1+)

- Configure external directory services for S3 access
- LDAP groups can be granted S3 bucket access
- Fast bind mode for AD authentication
- Access key format for LDAP: `"NTAPFASTBIND" + base64(username:password)`

### Prerequisites
1. SVM with S3 server
2. DNS configured
3. Self-signed root CA of LDAP server installed
4. LDAP client with TLS configured

### Configuration
```
# Set name service to LDAP
ns-switch modify -vserver <svm> -database group -sources files,ldap
ns-switch modify -vserver <svm> -database passwd -sources files,ldap

# Grant LDAP group access to bucket
vserver object-store-server bucket policy add-statement -bucket <name> -effect allow -action GetObject,PutObject,DeleteObject,ListBucket -principal nasgroup/<ldap_group> -resource <bucket>,<bucket>/*
```

## CORS Configuration (ONTAP 9.8+)

```
# Create CORS rule
vserver object-store-server bucket cors-rule create -vserver <svm> -bucket <name> -index <n> -allowed-origins <origins> -allowed-methods GET,PUT,POST,DELETE -allowed-headers * -max-age-seconds 3600

# Show CORS rules
vserver object-store-server bucket cors-rule show -vserver <svm> -bucket <name>

# Delete CORS rule
vserver object-store-server bucket cors-rule delete -vserver <svm> -bucket <name> -index <n>
```
