---
name: volume-management
description: 'Create, resize, move, and manage NetApp ONTAP volumes. Use when: creating volume, resizing volume, moving volume, volume offline, volume online, changing junction path, modifying volume attributes, tiering policy, snapshot policy, export policy, volume clone. Covers NAS and SAN volume operations.'
argument-hint: 'Specify operation (create, resize, move) and volume details'
---

# Volume Management

## When to Use
- Creating  volumes on a cluster
- Resizing, moving, or modifying existing volumes
- Changing volume properties (junction path, export policy, snapshot policy, tiering)
- Volume clone operations

## Key Concepts (from ONTAP 9 docs)
- Volumes must have a **junction path** for NAS access (e.g., `/data`, `/eng/home`)
- **Thin provisioning** (`-space-guarantee none`): most common, doesn't pre-reserve aggregate space
- **Thick provisioning** (`-space-guarantee volume`): reserves full space, use for SAN LUNs
- **FlexVol**: max 100TB (300TB with large-size, ONTAP 9.12.1 P2+)
- **FlexGroup**: up to 60PB across 200 member volumes, for massive namespaces
- Security styles: `unix` (NFS), `ntfs` (SMB/Hyper-V/SQL), `mixed` (multi-protocol)
- Do NOT place SAN LUNs and NAS shares on the same FlexVol volume
- Tiering policies (FabricPool): `none`, `snapshot-only`, `auto`, `all`
- For detailed reference, see [ONTAP 9 Volume Reference](./references/volume-ontap-reference.md)

## Procedure

### Step 0 — Gather Requirements
Ask the user:
1. **Cluster** (cluster-prod or cluster-dr)
2. **SVM** (vserver) for the volume
3. **Operation** (create, resize, move, etc.)
4. For create: volume name, size, aggregate, protocol (NFS/CIFS/iSCSI), junction path

### List Existing Volumes
```powershell
Get-ProdCsv -Command "vol show -vserver <svm> -fields volume,size,used,percent-used,aggregate,state,junction-path,type"
```

### Create a Volume
```powershell
# NAS volume with junction path
Prod-s -Command "vol create -vserver <svm> -volume <vol_name> -aggregate <aggr> -size <size> -junction-path /<path> -security-style unix -space-guarantee none"

# SAN volume (no junction path)
Prod-s -Command "vol create -vserver <svm> -volume <vol_name> -aggregate <aggr> -size <size> -space-guarantee none"
```

### Resize a Volume
```powershell
Prod-s -Command "vol size -vserver <svm> -volume <vol_name> --size <size>"
```

### Move a Volume
```powershell
# Start volume move
Prod-s -Command "vol move start -vserver <svm> -volume <vol_name> -destination-aggregate <dest-aggr>"

# Check move status
Get-ProdCsv -Command "vol move show -fields volume,vserver,state,phase,percent-complete"
```

### Modify Volume Properties
```powershell
# Change junction path
Prod-s -Command "vol mount -vserver <svm> -volume <vol_name> -junction-path /<-path>"

# Change export policy
Prod-s -Command "vol modify -vserver <svm> -volume <vol_name> -policy <export-policy-name>"

# Change snapshot policy
Prod-s -Command "vol modify -vserver <svm> -volume <vol_name> -snapshot-policy <policy-name>"

# Change tiering policy
Prod-s -Command "vol modify -vserver <svm> -volume <vol_name> -tiering-policy auto"

# Set autosize
Prod-s -Command "vol autosize -vserver <svm> -volume <vol_name> -mode grow_shrink -maximum-size <max> -grow-thresh-percent 85 -shrink-thresh-percent 50"
```

### Volume Clone
```powershell
Prod-s -Command "vol clone create -vserver <svm> -flexclone <clone_name> -parent-volume <parent_vol>"
```

### Delete a Volume
**WARNING:** Confirm with user before running.
```powershell
# Unmount first
Prod-s -Command "vol unmount -vserver <svm> -volume <vol_name>"

# Take offline
Prod-s -Command "vol offline -vserver <svm> -volume <vol_name>"

# Destroy
Prod-s -Command "vol destroy -vserver <svm> -volume <vol_name>"
```

## Safety
- Always confirm `vol offline` and `vol destroy` with the user
- Verify the correct SVM and volume name before destructive operations
- Check if the volume has SnapMirror relationships before deleting
