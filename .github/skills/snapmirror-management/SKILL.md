---
name: snapmirror-management
description: 'Manage NetApp SnapMirror relationships. Use when: creating snapmirror, breaking snapmirror, resyncing, initializing transfer, checking replication status, failover, failback, volume replication, data protection, DP volumes. Covers volume-level and SVM-level SnapMirror operations.'
argument-hint: 'Specify operation (create, break, resync, status) and source/destination'
---

# SnapMirror Management

## When to Use
- Creating new SnapMirror replication relationships
- Checking SnapMirror health / status / lag
- Breaking mirrors for failover
- Resyncing after failover
- Updating or modifying replication schedules

## Key Concepts (from ONTAP 9 docs)
- **XDP** is the default relationship type since ONTAP 9.4 (replaces DP)
- Default policies: `MirrorAllSnapshots` (mirrors all), `MirrorLatest` (mirrors latest only), `MirrorAndVault` (DR + retention)
- SnapMirror Synchronous (SM-S) available since ONTAP 9.5 for zero RPO (latency ≤10ms)
- Volume paths: `<svm>:<volume>` | SVM paths: `<svm>:` (trailing colon)
- Initialization performs a baseline transfer of all data blocks
- Updates are asynchronous per schedule; each update creates snapshot → transfers delta
- Peering requires intercluster LIFs, ports 11104/11105 open, TLS 1.2+ encryption
- For detailed reference, see [ONTAP 9 SnapMirror Reference](./references/snapmirror-ontap-reference.md)

## Procedure

### Step 0 — Identify Clusters and Relationship
Ask the user:
1. **Source cluster** and **SVM/volume**
2. **Destination cluster** and **SVM/volume**
3. **Operation** needed (create, status, break, resync, etc.)

### Show SnapMirror Status
```powershell
# All relationships on source
Get-<Prefix>Csv -Command "snapmirror show -fields source-path,destination-path,state,status,healthy,lag-time,schedule"

# All relationships on destination
<cluster-ssh> -Command "snapmirror show -fields source-path,destination-path,state,status,healthy,lag-time,schedule"
```

### Create Volume-Level SnapMirror
```powershell
# 1. Create destination volume (DP type)
<cluster-ssh> -Command "vol create -vserver <dest-svm> -volume <dest-vol> -aggregate <aggr> -size <size> -type DP"

# 2. Create SnapMirror relationship
<cluster-ssh> -Command "snapmirror create -source-path <src-svm>:<src-vol> -destination-path <dest-svm>:<dest-vol> -type XDP -policy MirrorAllSnapshots -schedule hourly"

# 3. Initialize
<cluster-ssh> -Command "snapmirror initialize -destination-path <dest-svm>:<dest-vol>"
```

### Manual Update (Trigger Transfer)
```powershell
<cluster-ssh> -Command "snapmirror update -destination-path <dest-svm>:<dest-vol>"
```

### Break Mirror (Failover)
**WARNING:** Confirm with user before running.
```powershell
<cluster-ssh> -Command "snapmirror break -destination-path <dest-svm>:<dest-vol>"
```

### Resync (After Failover)
```powershell
# Resync back to original direction
<cluster-ssh> -Command "snapmirror resync -destination-path <dest-svm>:<dest-vol>"

# Or reverse resync (make old source the new destination)
<cluster-ssh> -Command "snapmirror resync -destination-path <src-svm>:<src-vol>"
```

### Abort a Running Transfer
```powershell
<cluster-ssh> -Command "snapmirror abort -destination-path <dest-svm>:<dest-vol>"
```

### Delete Relationship
**WARNING:** Confirm with user before running.
```powershell
# Release on source (cleans up snapshots)
<cluster-ssh> -Command "snapmirror release -destination-path <dest-svm>:<dest-vol>"

# Delete on destination
<cluster-ssh> -Command "snapmirror delete -destination-path <dest-svm>:<dest-vol>"
```

### Check Transfer History
```powershell
<cluster-ssh> -Command "snapmirror show-history -destination-path <dest-svm>:<dest-vol>"
```

### Throttle Bandwidth
```powershell
# Limit outgoing replication bandwidth (KBps). Example: 100 Mbps = 12500 KBps
<cluster-ssh> -Command "options -option-name replication.throttle.outgoing.max_kbs 12500"
```

## Safety
- Never run `snapmirror break` or `snapmirror delete` without explicit user confirmation
- Always verify source and destination paths before creating relationships
- Check current state before performing operations
- Verify peering is healthy before creating new relationships
