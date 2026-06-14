# Volume Management Reference — From ONTAP 9 Documentation

## Volume Types

### FlexVol Volumes
- Standard volumes with max size 100TB (or 300TB with large-size enabled in ONTAP 9.12.1 P2+)
- Must specify junction path for NAS access (or mount later)
- Can be moved between aggregates non-disruptively
- Support deduplication, compression, compaction

### FlexGroup Volumes
- Supports up to **400 billion files** with up to 200 constituent member volumes
- Max size 60PB (with large-size enabled)
- Auto-balances load and space across members
- Best for single namespace needing petabytes of storage

### DP Volumes
- Data protection type — used as SnapMirror destinations
- Read-only until SnapMirror relationship is broken
- Created automatically in SVM-DR, or manually for volume-level replication

## Volume Provisioning Options

| Provisioning | `-space-guarantee` | Overwrites | Storage Efficiency | Notes |
|-------------|-------------------|------------|-------------------|-------|
| **Thin** | `none` | Not guaranteed | Supported | Can overcommit aggregate. Most common for NAS. |
| **Thick** | `volume` | Guaranteed | Supported | Reserves full space from aggregate at creation. |
| **Semi-thick** | (use `-space-slo semi-thick`) | Best effort | Not supported | Deletes snapshots/clones to free space if needed. |

**Recommendation**: Use thin provisioning (`-space-guarantee none`) for most workloads. Use thick provisioning for latency-sensitive SAN LUNs.

## Volume Creation Requirements

- SVM and aggregate must already exist
- Must include a **junction path** for NAS data access (directly under root `/_vol` or existing dir `/existing_dir/_vol`)
- If aggregate list is configured on SVM, aggregate must be in the list

### Create Syntax
```
volume create -vserver <svm> -volume <name> -aggregate <aggr> -size {integer[KB|MB|GB|TB|PB]} -security-style {ntfs|unix|mixed} -junction-path <path> [-policy <export_policy>] [-space-guarantee none]
```

### Large Volume/File Support (ONTAP 9.12.1 P2+)
```
volume create -vserver <svm> -volume <name> -aggregate <aggr> -is-large-size-enabled true
```
- Max volume size: 300TB
- Max FlexGroup: 60PB
- Max file/LUN: 128TB

## Volume Operations

### Resize
```
volume size -vserver <svm> -volume <name> --size <size>
```

### Move (Non-disruptive)
```
volume move start -vserver <svm> -volume <name> -destination-aggregate <dest_aggr>
volume move show -fields volume,vserver,state,phase,percent-complete
```

### Mount / Unmount
```
volume mount -vserver <svm> -volume <name> -junction-path <path>
volume unmount -vserver <svm> -volume <name>
```

### Modify Properties
```
volume modify -vserver <svm> -volume <name> [-policy <export_policy>] [-snapshot-policy <policy>] [-tiering-policy <policy>] [-space-guarantee none|volume]
```

### Autosize
```
volume autosize -vserver <svm> -volume <name> -mode {off|grow|grow_shrink} -maximum-size <max> -grow-thresh-percent <pct> -shrink-thresh-percent <pct>
```

### Clone
```
volume clone create -vserver <svm> -flexclone <clone_name> -parent-volume <parent> [-junction-path <path>]
```

### Delete (DESTRUCTIVE — requires confirmation)
```
volume unmount -vserver <svm> -volume <name>
volume offline -vserver <svm> -volume <name>
volume destroy -vserver <svm> -volume <name>
```

## Volume Rehost (Move Between SVMs)
Starting ONTAP 9.12.1, supports NFS, SMB, iSCSI volumes:
```
volume rehost -vserver <source_svm> -volume <name> -destination-vserver <dest_svm>
```

## Security Styles

| Style | Description | Use When |
|-------|-------------|----------|
| `unix` | UNIX permissions (mode bits, NFSv4 ACLs) | NFS environments |
| `ntfs` | Windows NTFS permissions | SMB/CIFS, Hyper-V, SQL Server |
| `mixed` | Both UNIX and NTFS | Multi-protocol NFS+SMB |

## SAN Volume Recommendations
- Do NOT place SAN LUNs and NAS shares on the same FlexVol volume
- Provision separate FlexVol volumes for SAN LUNs and NAS shares
- Use space-reserved LUNs on thick-provisioned volumes for guaranteed overwrites

## Tiering Policies (FabricPool)

| Policy | Behavior |
|--------|----------|
| `none` | Data stays on performance tier |
| `snapshot-only` | Only snapshot data moves to cloud |
| `auto` | C data from snapshots and active file system moves to cloud |
| `all` | All data moves to cloud |

## Snapshot Policies
Default built-in policies: `default`, `default-1weekly`, `none`

```
# View policies
snapshot policy show -fields policy,enabled,schedule,count

# Modify volume snapshot policy
volume modify -vserver <svm> -volume <name> -snapshot-policy <policy>
```
