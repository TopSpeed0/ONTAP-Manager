# SnapMirror Reference — From ONTAP 9 Documentation

## SnapMirror Asynchronous DR

SnapMirror is disaster recovery technology designed for failover from primary storage to secondary storage at a geographically remote site. It creates a replica (mirror) of working data in secondary storage.

### Data Protection Relationships
- Data is mirrored at the **volume level**
- Clusters and SVMs must be **peered** before creating relationships
- You can create relationships directly between volumes OR between SVMs

### How Initialization Works (Baseline Transfer)
Under default `MirrorAllSnapshots` policy:
1. Creates a snapshot of the source volume
2. Transfers the snapshot and all data blocks it references to destination
3. Transfers remaining less-recent snapshots for corruption recovery

### How Updates Work
- Updates are **asynchronous**, following the configured schedule
- Retention mirrors the snapshot policy on the source
- Each update: creates snapshot on source → transfers it + any  snapshots since last update

### Default Policies

| Policy | Type | Behavior |
|--------|------|----------|
| `MirrorAllSnapshots` | async-mirror | Mirrors ALL snapshots (SnapMirror-created + source snapshots) |
| `MirrorLatest` | async-mirror | Mirrors ONLY the SnapMirror-created snapshot |
| `MirrorAndVault` | mirror-vault | Unified replication (DR + long-term retention) |
| `XDPDefault` | mirror-vault | Same as MirrorAndVault |

### XDP vs DP
- **XDP** is the default since ONTAP 9.4
- XDP provides version-flexible replication (source and destination can run different ONTAP versions)
- DP relationships are automatically converted to XDP on upgrade

## SnapMirror Synchronous (SM-S)

- Available since ONTAP 9.5 on all FAS and AFF platforms with ≥16 GB memory
- Provides **synchronous** data replication at volume level (zero RPO)
- Per-HA pair limits:
  - AFF/ASA: 400 (ONTAP 9.11.1+), 200 (9.10.1), 160 (9.9.1), 80 (earlier)
  - FAS: 80 (all versions)
  - ONTAP Select: 40 (all versions)

### Synchronous Supported Protocols
- FC (ONTAP 9.5+, latency ≤10ms)
- iSCSI (ONTAP 9.5+)
- NFS v4.0/v4.1 (ONTAP 9.6+), NFS v4.2 (ONTAP 9.10.1+)
- SMB 2.0+ (ONTAP 9.6+)
- FC-NVMe (ONTAP 9.7+), NVMe/TCP (ONTAP 9.10.1+)

## SnapMirror Unified Replication (Vault)

Configures destination for **both** DR and long-term retention:
- Uses `mirror-vault` policy type
- Different retention rules for different snapshot labels
- Snapshots can be kept longer on destination than source

## Key CLI Commands

### Create Volume SnapMirror
```
# On destination cluster:
snapmirror create -source-path <src_svm>:<src_vol> -destination-path <dst_svm>:<dst_vol> -type XDP -policy <policy> -schedule <schedule>
snapmirror initialize -destination-path <dst_svm>:<dst_vol>
```

### Create SVM SnapMirror
```
# Note: colon after SVM name, no volume
snapmirror create -source-path <src_svm>: -destination-path <dst_svm>: -type XDP -policy <policy> -schedule <schedule> -identity-preserve true
snapmirror initialize -source-path <src_svm>: -destination-path <dst_svm>:
```

### Path Syntax
- **Volume**: `<svm_name>:<volume_name>` (e.g., `svm1:vol1`)
- **SVM**: `<svm_name>:` (e.g., `svm1:`) — note the trailing colon
- **SVM with cluster**: `<cluster>://<svm_name>` (e.g., `cluster1://svm1`)

### Throttle Bandwidth
```
# Set max bandwidth for outgoing transfers (KBps)
options -option-name replication.throttle.outgoing.max_kbs <KBps>
# Example: 100 Mbps = 12500 KBps
options -option-name replication.throttle.outgoing.max_kbs 12500
```

## Peering Requirements

### Cluster Peering
- Every intercluster LIF on local cluster must communicate with every intercluster LIF on remote cluster
- IP addresses should ideally be in the same subnet (simpler, not required)
- One intercluster LIF per node required
- Max 255 peer clusters per cluster
- Ports 11104 and 11105 must be open (bidirectional TCP)
- HTTPS must be accessible between intercluster LIFs
- TLS 1.2 AES-256 GCM encryption by default (ONTAP 9.6+)
- TLS 1.3 support (ONTAP 9.15.1+)

### SVM Peering
- Required for SnapMirror between SVMs on different clusters
- Uses the intercluster network established by cluster peering
- Applications specify what the peer relationship is used for (e.g., `snapmirror`)
