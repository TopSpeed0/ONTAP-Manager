# SVM-DR Reference — From ONTAP 9 Documentation

## Supported Relationship Types

| Policy Type | Relationship Type | Description |
|-------------|-------------------|-------------|
| `async-mirror` | SnapMirror DR | Destination contains only snapshots currently on source |
| `mirror-vault` | Unified Replication | Destination configured for both DR and long-term retention |

Starting ONTAP 9.9.1 with `mirror-vault` policy:
- Different snapshot policies can exist on source and destination
- Destination snapshots are NOT overwritten by source during normal operations, updates, resync, break, or flip-resync

## XDP vs DP Mode
- **ONTAP 9.4+**: SVM data protection relationships default to **XDP** mode
- If you specify `DP`, it becomes `XDP` with `MirrorAllSnapshots` policy
- If you specify nothing, defaults to `XDP` with `MirrorAllSnapshots` policy
- If you specify `XDP`, defaults to `MirrorAndVault` (Unified replication)

## identity-preserve Option

| Option | What Gets Replicated |
|--------|---------------------|
| `-identity-preserve true` | Entire SVM configuration (LIFs, NFS exports, SMB shares, RBAC, protocols, name services) |
| `-identity-preserve false` | Only volumes, authentication/authorization, protocol and name service settings |

## discard-configs network Option
Use `snapmirror policy create -discard-configs network` to **exclude LIFs and related network settings** when source and destination SVMs are in different subnets.

## What Gets Replicated (identity-preserve true)

### Always Replicated
- NAS LIFs (with `-discard-configs network`: No)
- SMB server, local groups, local user, privilege, shadow copy, BranchCache, server options
- NFS export policies and rules, NFS server
- Security certificates, login user, public key, role configuration, SSL
- DNS and DNS hosts, UNIX user/group, Kerberos, LDAP/LDAP client, Netgroup, NIS
- Volumes, snapshots, snapshot policies, efficiency policies, quota policies
- QoS policy groups
- LUNs (object only — igroups, portsets, serial numbers are NOT replicated)

### NOT Replicated
- SAN LIFs
- Broadcast domains, subnets, IPspaces
- Fibre Channel (FC), iSCSI (protocol-level)
- igroups, portsets, LUN serial numbers
- Root volume attributes (state, space guarantee, size, autosize)

## SVM-DR Storage Limits

| Object | Limit |
|--------|-------|
| SVM | 300 FlexVol volumes |
| HA pair | 1,000 FlexVol volumes |
| Cluster | 128 SVM disaster relationships |

## Aggregate Selection for Destination Volumes
- Volumes always placed on **non-root** aggregates
- Selected based on **available free space** and **fewest hosted volumes**
- FabricPool source volumes → placed on FabricPool destination aggregates with same tiering policy
- Flash Pool source → Flash Pool destination (if available with enough space)
- `-space-guarantee volume` → only aggregates with free space > volume size

## Minimum RPO (Schedule)
- **FlexVol** volumes: 15 minutes
- **FlexGroup** volumes: 30 minutes

## SVM-DR Workflow Steps (CLI)

### Create Relationship
```
vserver create -vserver <svm_name> -subtype dp-destination
vserver peer create ...
job schedule cron create -name <schedule> -dayofweek <day> -hour <hour> -minute <min>
snapmirror create -source-path <src_svm>: -destination-path <dst_svm>: -type XDP -schedule <schedule> -policy MirrorAllSnapshots -identity-preserve true
vserver stop -vserver <dst_svm>
snapmirror initialize -source-path <src_svm>: -destination-path <dst_svm>:
```

**IMPORTANT**: You must include a colon (`:`) after the SVM name in `-source-path` and `-destination-path`.

### Exclude LIFs (Different Subnets)
```
snapmirror policy create -vserver <svm> -policy DR_exclude_LIFs -type async-mirror -discard-configs network
snapmirror create -source-path <src_svm>: -destination-path <dst_svm>: -type XDP -schedule <schedule> -policy DR_exclude_LIFs -identity-preserve true
```

### Failover (Activate Destination)
```
snapmirror quiesce -source-path <src_svm>: -destination-path <dst_svm>:
snapmirror abort -source-path <src_svm>: -destination-path <dst_svm>:
snapmirror break -source-path <src_svm>: -destination-path <dst_svm>:
vserver stop -vserver <src_svm>    # Only if identity-preserve true
vserver start -vserver <dst_svm>
```

### Reactivate Source SVM (Failback)
```
# 1. Create reverse relationship from original source
snapmirror create -source-path <dst_svm>: -destination-path <src_svm>:

# 2. Reverse resync
snapmirror resync -source-path <dst_svm>: -destination-path <src_svm>:
# Optional: -quick-resync true (ONTAP 9.11.1+, faster but may increase space usage)

# 3. Stop destination (currently serving data)
vserver stop -vserver <dst_svm>

# 4. Final update
snapmirror update -source-path <dst_svm>: -destination-path <src_svm>:

# 5. Quiesce
snapmirror quiesce -source-path <dst_svm>: -destination-path <src_svm>:

# 6. Break reversed relationship
snapmirror break -source-path <dst_svm>: -destination-path <src_svm>:

# 7. Start original source
vserver start -vserver <src_svm>

# 8. Reestablish original protection
snapmirror resync -source-path <src_svm>: -destination-path <dst_svm>:
```

## Version Requirements
- Source and destination clusters must run the **same ONTAP version** (version-independence NOT supported for SVM replication)
- ONTAP 9.6+: FabricPool supported
- ONTAP 9.9.1+: mirror-vault policy with independent snapshot policies
- ONTAP 9.11.1+: quick-resync option
- ONTAP 9.12.1+: Autonomous Ransomware Protection supported

## Same-Name SVM Peering

When source and destination SVMs share the **same name**, ONTAP cannot distinguish between them in peer and SnapMirror commands. This is common when you want the DR SVM to keep the same name for identity-preserve failover.

### Problem
```
vserver peer create -vserver svm_X -peer-vserver svm_X -peer-cluster dest_cluster -applications snapmirror
→ Error: "Vserver name conflicts with one of the following..."
```

### Solution
1. **On source**: use `-local-name` to assign an alias for the remote peer:
   ```
   vserver peer create -vserver svm_X -peer-vserver svm_X -peer-cluster dest_cluster -applications snapmirror -local-name svm_X_dr
   ```
2. ONTAP may auto-accept and auto-assign a `.1` suffix on the destination (e.g., `svm_X.1`)
3. **On destination**: rename the auto-assigned local-name to something meaningful:
   ```
   vserver peer modify-local-name -peer-cluster source_cluster -peer-vserver svm_X --name svm_X_med1
   ```
4. **In `snapmirror create` on destination**: use the peer local-name as source-path:
   ```
   snapmirror create -source-path svm_X_med1: -destination-path svm_X: -type XDP -identity-preserve true
   ```

### Key Point
The peer local-name is a **local alias only** — it doesn't change the actual SVM name. It's just how that cluster refers to the remote SVM to avoid ambiguity.

## S3/Object Store Cleanup Before SVM-DR

If the source SVM ever had S3 (ONTAP S3 object storage) configured, even if disabled, leftover objects will block SVM-DR creation with:
```
Error: "...contains either an object store server, object store policy, object store user or object store bucket"
```

### Cleanup Order (delete in this sequence)
```
vserver object-store-server bucket delete -vserver <svm> -bucket <name>
vserver object-store-server user delete -vserver <svm> -user <name>
vserver object-store-server policy delete -vserver <svm> -policy <name>
vserver object-store-server delete -vserver <svm>
```

### Discovery Commands
```
vserver object-store-server show -vserver <svm>
vserver object-store-server bucket show -vserver <svm>
vserver object-store-server user show -vserver <svm>
vserver object-store-server policy show -vserver <svm>
```

## MirrorAndVault (Default Unified Replication Policy)

When creating SVM-DR with `-type XDP` and no explicit `-policy`, ONTAP defaults to **MirrorAndVault**:

- Creates a fresh `sm_created` snapshot at every update (keep 1)
- Transfers snapshots labeled `daily` (keep 7) and `weekly` (keep 52)
- Provides both DR (latest data) and archiving (labeled snapshots) in one relationship
- Alternative: `MirrorAllSnapshots` for pure DR (all snapshots, no label filtering)
- ONTAP 9.14.1+: Consistency groups with SVM-DR (max 32 relationships)
