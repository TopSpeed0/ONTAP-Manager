---
name: svm-dr
description: 'Automate SVM-DR (Storage Virtual Machine Disaster Recovery) setup between two NetApp ONTAP clusters. Use when: creating SVM-DR, setting up SVM disaster recovery, replicating SVM, migrating SVM, SVM failover planning. Covers peer setup, identity-preserve mirror creation, initialization, and validation.'
argument-hint: 'Provide source and destination cluster names (e.g., cluster-prod to cluster-dr)'
---

# SVM-DR (Storage Virtual Machine Disaster Recovery)

## When to Use
- Setting up SVM-level disaster recovery between two ONTAP clusters
- Migrating SVM workloads to another cluster
- Creating an identity-preserve SVM mirror for failover

## Prerequisites
- Both clusters must be accessible via SSH (use `Prod-s`, `Dr-s`, or the appropriate alias)
- Cluster peering and intercluster LIFs must be in place (or will be created in Step 1)
- The destination cluster must have available aggregates
- **Source and destination clusters must run the same ONTAP version** (version-independence not supported for SVM replication)
- Max limits: 300 FlexVol volumes per SVM, 128 SVM-DR relationships per cluster
- **No S3/object-store remnants on source SVM** — leftover S3 users, policies, buckets, or server configs will block SVM-DR creation (see Pre-flight Cleanup below)

## Key Concepts (from ONTAP 9 docs)
- **identity-preserve true**: Replicates entire SVM config (LIFs, NFS exports, SMB shares, RBAC, name services)
- **identity-preserve false**: Replicates only volumes + authentication/authorization
- **-discard-configs network**: Excludes LIFs and network settings (use when source/dest are in different subnets)
- Policy types: `async-mirror` (SnapMirror DR) or `mirror-vault` (unified replication with long-term retention)
- **XDP** is the default relationship type since ONTAP 9.4
- Minimum RPO: 15 min (FlexVol), 30 min (FlexGroup)
- **IMPORTANT**: Always include a colon (`:`) after SVM name in `-source-path` and `-destination-path`
- For detailed reference, see [ONTAP 9 SVM-DR Reference](./references/svm-dr-ontap-reference.md)

## Procedure

### Step 0 — Gather Information & Pre-flight Cleanup
Ask the user for:
1. **Source cluster** (e.g., `cluster-prod`) and the **SVM name** to protect
2. **Destination cluster** (e.g., `cluster-dr`)
3. **Destination aggregate(s)** to use (or discover automatically)
4. **Network details** — whether to replicate LIFs or create  ones at DR site

**Pre-flight checks — run ALL of these before proceeding:**
```powershell
# Check for stale vserver peers that may conflict
Prod-s -Command "vserver peer show -vserver <source-svm> -fields peer-vserver,peer-cluster,peer-state"

# Check for leftover S3/object-store configs (these BLOCK SVM-DR)
Prod-s -Command "vserver object-store-server show -vserver <source-svm>"
Prod-s -Command "vserver object-store-server bucket show -vserver <source-svm>"
Prod-s -Command "vserver object-store-server user show -vserver <source-svm>"
Prod-s -Command "vserver object-store-server policy show -vserver <source-svm>"

# Check for existing SnapMirror relationships on source SVM
Prod-s -Command "snapmirror show -source-path <source-svm>: -fields destination-path,state"

# Check if destination SVM already exists
Dr-s -Command "vserver show -vserver <dest-svm>"

# Check destination aggregate free space
Dr-s -Command "aggr show -fields aggregate,size,availsize,node"
```

**If S3 remnants are found, delete them (with user confirmation):**
```powershell
# Delete in order: buckets → users → policies → server
Prod-s -Command "vserver object-store-server bucket delete -vserver <svm> -bucket <name>"
Prod-s -Command "vserver object-store-server user delete -vserver <svm> -user <name>"
Prod-s -Command "vserver object-store-server policy delete -vserver <svm> -policy <name>"
Prod-s -Command "vserver object-store-server delete -vserver <svm>"
```

**If stale vserver peers conflict, delete them (with user confirmation):**
```powershell
Prod-s -Command "vserver peer delete -vserver <source-svm> -peer-vserver <stale-peer>"
```

Confirm the plan with the user before proceeding.

### Step 1 — Verify / Create Cluster Peering
```powershell
# Check existing cluster peers on source
Prod-s -Command "cluster peer show"

# Check existing cluster peers on destination
Dr-s -Command "cluster peer show"
```
If peering does not exist, create intercluster LIFs and then peer the clusters:
```powershell
# Source: create intercluster LIFs (one per node)
Prod-s -Command "net int create -vserver <source-cluster> -lif <ic-lif-name> -role intercluster -home-node <node> -home-port <port> -address <ip> -netmask <mask>"

# Destination: create intercluster LIFs (one per node)
Dr-s -Command "net int create -vserver <dest-cluster> -lif <ic-lif-name> -role intercluster -home-node <node> -home-port <port> -address <ip> -netmask <mask>"

# Source: create cluster peer (generates passphrase)
Prod-s -Command "cluster peer create -generate-passphrase -offer-expiration 2days -peer-addrs <dest-ic-lif-ips>"

# Destination: accept peering
Dr-s -Command "cluster peer create -peer-addrs <source-ic-lif-ips> -passphrase <passphrase>"
```

### Step 2 — Verify / Create Vserver Peering
```powershell
# Check existing vserver peers
Prod-s -Command "vserver peer show"

# Create vserver peer
Prod-s -Command "vserver peer create -vserver <source-svm> -peer-vserver <dest-svm> -peer-cluster <dest-cluster> -applications snapmirror"

# Accept on destination
Dr-s -Command "vserver peer accept -vserver <dest-svm> -peer-vserver <source-svm>"
```

#### Same-Name SVM Handling (IMPORTANT)
When source and destination SVMs have the **same name** (e.g., both `svm_nas_K8s`):
- The `vserver peer create` command will fail with: *"Vserver name conflicts..."*
- **Solution**: Use `-local-name` to assign an alias for the peer on each cluster:
```powershell
# On source: create peer with local-name for the destination
Prod-s -Command "vserver peer create -vserver <svm> -peer-vserver <svm> -peer-cluster <dest-cluster> -applications snapmirror -local-name <svm>_dr"
```
- ONTAP may auto-accept the peer and auto-assign a `.1` suffix on the destination side
- If the auto-assigned name is not clear, rename it on the destination:
```powershell
# On destination: rename the peer local-name to something meaningful
Dr-s -Command "vserver peer modify-local-name -peer-cluster <source-cluster> -peer-vserver <svm> --name <svm>_med1"
```
- **The renamed local-name must be used in `snapmirror create -source-path`** on the destination cluster
- Example: if destination renamed peer to `svm_nas_K8s_med1`, then:
```powershell
Dr-s -Command "snapmirror create -source-path svm_nas_K8s_med1: -destination-path svm_nas_K8s: ..."
```

### Step 3 — Create Destination SVM (if not already present)
On the destination cluster, create the SVM with `subtype dp-destination`:
```powershell
Dr-s -Command "vserver create -vserver <dest-svm> -subtype dp-destination"
```
Verify:
```powershell
Dr-s -Command "vserver show -vserver <dest-svm> -fields vserver,type,subtype,admin-state"
# Expected: type=data, subtype=dp-destination, admin-state=running
```

### Step 3b — Create Replication Schedule (optional)
If you want scheduled updates (not just manual):
```powershell
Dr-s -Command "job schedule cron create -name svm_dr_sched -dayofweek * -hour 0 -minute 0"
```

### Step 4 — Create SnapMirror Relationship (Identity-Preserve)
```powershell
# On the destination cluster — note the colon after SVM names
# If same-name SVMs: use the peer local-name for source-path (see Step 2)
Dr-s -Command "snapmirror create -source-path <source-svm-or-peer-localname>: -destination-path <dest-svm>: -type XDP -identity-preserve true"

# Optionally add: -schedule svm_dr_sched -policy <policy>
```

**Policy behavior:**
- If you omit `-policy`, ONTAP defaults to **MirrorAndVault** (unified replication)
- `MirrorAndVault`: mirrors latest data + retains daily (7) and weekly (52) labeled snapshots
- `MirrorAllSnapshots`: mirrors all snapshots from source (pure DR, no archiving)
- Both work with `identity-preserve true`

### Step 5 — Initialize the SnapMirror Transfer
```powershell
Dr-s -Command "snapmirror initialize -source-path <source-svm>: -destination-path <dest-svm>:"
```

### Step 6 — Validate
```powershell
# Check SnapMirror status
Dr-s -Command "snapmirror show -fields source-path,destination-path,state,status,healthy"

# Verify SVM on destination
Dr-s -Command "vserver show -vserver <dest-svm> -fields state,subtype,admin-state"

# Verify volumes replicated
Dr-s -Command "vol show -vserver <dest-svm> -fields volume,type,state"
```

## Failover (Activate DR SVM)
If the user needs to activate the DR SVM, follow these steps **in order**:
```powershell
# 1. Quiesce — stop scheduled transfers
Dr-s -Command "snapmirror quiesce -source-path <source-svm>: -destination-path <dest-svm>:"

# 2. Abort — stop any ongoing transfers
Dr-s -Command "snapmirror abort -source-path <source-svm>: -destination-path <dest-svm>:"

# 3. Break the SnapMirror relationship
Dr-s -Command "snapmirror break -source-path <source-svm>: -destination-path <dest-svm>:"

# 4. If identity-preserve true was used, stop the source SVM first
Prod-s -Command "vserver stop -vserver <source-svm>"

# 5. Start the destination SVM
Dr-s -Command "vserver start -vserver <dest-svm>"
```
**WARNING:** Always confirm with the user before running `snapmirror break`.

## Reactivate Source SVM (Failback)
After a disaster is resolved and you want to reactivate the original source:
```powershell
# 1. Create reverse relationship (from original source cluster)
Prod-s -Command "snapmirror create -source-path <dest-svm>: -destination-path <source-svm>:"

# 2. Reverse resync (from original source cluster)
Prod-s -Command "snapmirror resync -source-path <dest-svm>: -destination-path <source-svm>:"
# Optional for ONTAP 9.11.1+: add -quick-resync true for faster resync

# 3. Stop the destination SVM (currently serving data)
Dr-s -Command "vserver stop -vserver <dest-svm>"

# 4. Final update
Prod-s -Command "snapmirror update -source-path <dest-svm>: -destination-path <source-svm>:"

# 5. Quiesce reversed relationship
Prod-s -Command "snapmirror quiesce -source-path <dest-svm>: -destination-path <source-svm>:"

# 6. Break reversed relationship
Prod-s -Command "snapmirror break -source-path <dest-svm>: -destination-path <source-svm>:"

# 7. Start original source SVM
Prod-s -Command "vserver start -vserver <source-svm>"

# 8. Re-establish original protection direction
Prod-s -Command "snapmirror resync -source-path <source-svm>: -destination-path <dest-svm>:"
```

## Troubleshooting

| Error Message | Cause | Fix |
|---------------|-------|-----|
| *"Vserver name conflicts..."* | Source and dest SVM have same name | Use `-local-name` on `vserver peer create` |
| *"contains either an object store server, policy, user or bucket"* | Leftover S3/object-store config on source SVM | Delete S3 users, policies, buckets, server (see Step 0) |
| *"Vserver peer relationship does not exist"* | Peer auto-accepted, no manual accept needed | Check `vserver peer show` — may already be `peered` |
| *"SVM-DR relationship not supported because they are on the same cluster"* | Same-name SVMs confuse ONTAP about source/dest | Use peer local-name in `-source-path` (see Step 2) |

## Real-World Example: svm_nas_K8s (cluster-prod → cluster-dr)

This was our first SVM-DR setup. Key lessons:
1. **S3 cleanup**: Source had leftover S3 user (`sm_s3_user`) and policy (`BackupAccesss`) from a previous config — had to delete both before `snapmirror create` would work
2. **Stale vserver peer**: Had an  peer `svm_nas_K8s ↔ svm_s3_prod` that needed deletion
3. **Same-name handling**: Both clusters use `svm_nas_K8s` — used `-local-name svm_nas_K8s_dr` on source, then renamed peer to `svm_nas_K8s_med1` on destination with `vserver peer modify-local-name`
4. **Source-path in snapmirror**: Used the destination's peer local-name: `snapmirror create -source-path svm_nas_K8s_med1: -destination-path svm_nas_K8s:`
5. **Policy**: Defaulted to `MirrorAndVault` (unified replication) — works well for DR + retention
6. **No need to stop dest SVM** before initialize when using identity-preserve (ONTAP handles it)

## References
- [ONTAP 9 SVM-DR Detailed Reference](./references/svm-dr-ontap-reference.md)
- [NetApp SVM-DR Documentation](https://docs.netapp.com/us-en/ontap/data-protection/replicate-entire-svm-config-task.html)
