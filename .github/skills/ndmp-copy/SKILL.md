---
name: ndmp-copy
description: 'Storage-to-storage file copy between NetApp clusters using NDMP. Use when: ndmpcopy, NDMP-Copy, backupuser with role backup, Ndmp_Copy.ps1, MSU_Files migration, cross-cluster file copy, <cluster-name> to <dest-cluster> copy, NDMP prerequisites.'
argument-hint: 'Specify source cluster/path and destination cluster/path'
---

# NDMP Copy

## When to Use
- Copying large file trees between NetApp clusters (storage-to-storage, no client hop)
- Migrating data via NDMP instead of CIFS/NFS
- Setting up `backupuser` with NDMP credentials on clusters

## Key Concepts
- **NDMP** = Network Data Management Protocol — transfers data directly between storage controllers
- **ndmpcopy** runs on a **node** (not SVM) via `run -node <node> ndmpcopy ...`
- Path format: `<mgmt-lif-ip>:/vserver/volume/path`
- Credentials: `backupuser:<ndmp-generated-password>` — NOT the normal SSH password
- Both clusters must have NDMP enabled cluster-wide and `node-scope-mode` OFF
- The source node's management LIF must be on the same node as the source volume's aggregate

## Prerequisites — Enable NDMP on a Cluster

Run these on **each** cluster (source and destination):

```ontap
# Enable NDMP cluster-wide
system services ndmp modify -node * -enable true -user-id root

# Enable ndmpcopy on all nodes
node run -node * -command options nodescope.reenabledcmds ndmpcopy

# Enable NDMP service on all nodes
system services ndmp on -node *

# Disable node-scope-mode (use cluster-level pathing)
system services ndmp node-scope-mode off

# Find the ADMIN (cluster) vserver name
vserver show -type admin

# Create backupuser with backup role
security login create -vserver <MGMT_Vserver> -username backupuser -application ssh -authmethod password -role backup

# Generate NDMP password (SAVE THIS!)
vserver services ndmp generate-password -vserver <MGMT_Vserver> -user backupuser

# Enable NDMP on the admin vserver
vserver services ndmp on -vserver <MGMT_Vserver>
```

## Procedure

### Step 0 — Gather Requirements
1. **Source cluster** and path (e.g., `<cluster-name>`, `/<svm-name>/infraops/MSU_Files`)
2. **Destination cluster** and path (e.g., `<dest-cluster>`, `/<dest-svm>/<dest-volume>/SecurityUpdates`)
3. **NDMP credentials** for both clusters (`backupuser:<ndmp-password>`)

### Step 1 — Find the Correct Node and LIF
```powershell
# Connect to source cluster
Connect-NcController -Name <cluster-name>

# Find which node owns the source volume's aggregate
$srcVol = Get-NcVol -Volume <vol_name>
$srcNode = (Get-NcAggr $srcVol.Aggregate).Nodes

# Find the node-mgmt LIF on that node
$srcLif = Get-NcNetInterface -Vserver <admin-vserver> -Role node_mgmt |
    Where-Object { $_.HomeNode -match $srcNode }
$srcIP = $srcLif.Address
```

### Step 2 — Build and Run the ndmpcopy Command
```powershell
$sshCmd = "run -node $srcNode ndmpcopy -sa backupuser:<src-ndmp-pw> -da backupuser:<dst-ndmp-pw> ${srcIP}:/svm/vol/path ${dstIP}:/svm/vol/path"

Invoke-NcSsh -ControllerName <cluster-name> -Command $sshCmd -Verbose
```

### Fallback (direct SSH)
```powershell
<cluster-ssh> -Command "run -node <node> ndmpcopy -sa <user>:<pw> -da <user>:<pw> <srcIP>:<srcPath> <dstIP>:<dstPath>"
```

## Known Use Cases
| Source | Destination | Path |
|--------|------------|------|
| <cluster-name> | <dest-cluster-fqdn> (DE) | `/<svm-name>/infraops/MSU_Files` → `/<dest-svm>/<dest-volume>/SecurityUpdates` |
| <cluster-name> | <alt-dest-cluster> (CYP) | `/<svm-name>/infraops/MSU_Files` → `/cyp_cifs/SecurityUpdates_vol/SecurityUpdates` |

## Full Script
The complete automation script is at: `scripts/ndmp-copy/Ndmp_Copy.ps1`

It handles: credential management, auto-detecting management LIFs per node, cross-cluster vs same-cluster copies, and building the full `ndmpcopy` command.
