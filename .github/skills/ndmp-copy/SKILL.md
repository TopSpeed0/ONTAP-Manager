---
name: ndmp-copy
description: 'Storage-to-storage file copy between NetApp clusters using NDMP. Use when: ndmpcopy, NDMP-Copy, backupuser with role backup, Ndmp_Copy.ps1, ndmp-copy.bat, cross-cluster file copy, same-cluster file copy, <cluster> to <cluster> copy, NDMP prerequisites, NDMP enable, ndmp generate-password, node-scope-mode.'
argument-hint: 'Specify source cluster/path and destination cluster/path'
---

# NDMP Copy

## When to Use
- Copying large file trees between NetApp clusters (storage-to-storage, no client hop)
- Copying files within the same cluster between volumes on different nodes
- Migrating data via NDMP instead of CIFS/NFS
- Setting up `backupuser` with NDMP credentials on clusters

## Key Concepts
- **NDMP** = Network Data Management Protocol — transfers data directly between storage controllers
- **ndmpcopy** runs on a **source node** (not SVM) via `run -node <node> ndmpcopy ...`
- Path format: `<node-mgmt-lif-ip>:/<vserver>/<volume>/<path>`
- Credentials: `backupuser:<ndmp-generated-password>` — NOT the normal SSH password
- Both clusters must have NDMP enabled cluster-wide and `node-scope-mode` OFF
- The script resolves node-mgmt LIFs for **both** source and destination volumes — each LIF must be on the same node that owns the respective volume's aggregate
- The `ndmpcopy` command always executes on the **source** node

## Prerequisites

### Enable NDMP on a Cluster

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

# Generate NDMP password (SAVE THIS — store in config.json NdmpPassword field!)
vserver services ndmp generate-password -vserver <MGMT_Vserver> -user backupuser

# Enable NDMP on the admin vserver
vserver services ndmp on -vserver <MGMT_Vserver>
```

### PowerShell Module
- Requires **`NetApp.ONTAP`** module (`Import-Module NetApp.ONTAP`)
- Uses `Connect-NcController`, `Get-NcVserver`, `Get-NcVol`, `Get-NcAggr`, `Get-NcNetInterface`, `Invoke-NcSsh`
- Credential caching: uses `Get-NcCredential` / `Add-NcCredential` — prompts interactively if no cached credential exists for a cluster

## Procedure

### Step 0 — Gather Requirements
1. **Source cluster** and path (e.g., `<src-alias>`, `/<svm-name>/<volume>/<path>`)
2. **Destination cluster** and path (e.g., `<dst-alias>`, `/<dst-svm>/<dst-volume>/<dst-path>`)
3. **NDMP credentials** for both clusters — stored in `config.json` per-cluster `NdmpPassword` field

### Step 1 — Auto-Detect Admin Vserver and Node-Mgmt LIFs

The script performs this automatically for **both** source and destination clusters:

```powershell
# 1. Connect to the cluster
Connect-NcController -Name <cluster-connect-name>

# 2. Find the admin vserver (auto-detect with fallback)
$adminSvm = (Get-NcVserver | Where-Object { $_.vserverType -eq "admin" }).Vserver
# Fallback if Get-NcVserver returns nothing:
if ($null -eq $adminSvm) { $adminSvm = (Get-NcCluster).NcController.Name }

# 3. Find node-mgmt LIFs (with fallback)
$lifs = Get-NcNetInterface -Vserver $adminSvm -FirewallPolicy mgmt -Role node_mgmt
# Fallback if the filtered query returns nothing:
if (-not $lifs) { $lifs = Get-NcNetInterface *mgmt* }

# 4. Extract volume name from path (splits on '/' — index 2 is the volume)
$volName = $SourcePath.Split('/')[2]
$vol = Get-NcVol -Volume $volName

# 5. Find which node owns the volume's aggregate
$node = (Get-NcAggr $vol.Aggregate).Nodes

# 6. Find the node-mgmt LIF on that specific node
$lif = $lifs | Where-Object { $_.HomeNode -match $node }
$lifIP = $lif.Address
```

### Step 2 — Cross-Cluster vs Same-Cluster Handling

- **Cross-cluster**: The script connects to the destination cluster separately to resolve the destination volume's node-mgmt LIF, then reconnects to the source cluster before executing `ndmpcopy`
- **Same-cluster**: Both source and destination LIFs are resolved from a single connection — no reconnection needed

### Step 3 — Build and Run the ndmpcopy Command
```powershell
# Credential + path assembly
$SAcred  = "<backupuser>:<src-ndmp-pw>"
$DAcred  = "<backupuser>:<dst-ndmp-pw>"
$SRCpath = "<src-lif-ip>:/<src-svm>/<src-vol>/<path>"
$DSTpath = "<dst-lif-ip>:/<dst-svm>/<dst-vol>/<path>"

# Execute on source node
$sshCmd = "run -node <src-node> ndmpcopy -sa $SAcred -da $DAcred $SRCpath $DSTpath"
Invoke-NcSsh -ControllerName <src-cluster> -Command $sshCmd -Verbose
```

### Fallback (direct SSH)
```powershell
<cluster-ssh> -Command "run -node <node> ndmpcopy -sa <user>:<pw> -da <user>:<pw> <srcIP>:/<src-path> <dstIP>:/<dst-path>"
```

## Full Script — `scripts/ndmp-copy/Ndmp_Copy.ps1`

The automation script is **config-driven** — it reads cluster definitions and NDMP passwords from `config.json`.

### Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `-SrcCluster` | string | No | `NDMP_Config.SrcCluster` | Source cluster Alias, ClusterName, or ConnectName |
| `-DstCluster` | string | No | `NDMP_Config.DstCluster` | Destination cluster Alias, ClusterName, or ConnectName |
| `-SourcePath` | string | No | `NDMP_Config.SRC` | NDMP source path, e.g. `/<svm>/<vol>/<path>` |
| `-DestPath` | string | No | `NDMP_Config.DST` | NDMP destination path, e.g. `/<svm>/<vol>/<path>` |

All parameters fall back to `NDMP_Config` defaults in `config.json` if not supplied.

### Script Logic Flow

1. Loads `config.json` from `$PSScriptRoot\..\..\config.json`
2. Falls back to `NDMP_Config` defaults for any missing parameters
3. Resolves source and destination clusters via `Find-ClusterConfig` (matches Alias, ClusterName, or ConnectName)
4. Reads `NdmpPassword` from each cluster's config entry
5. Imports `NetApp.ONTAP` module
6. Checks/prompts for ONTAP credentials via `Get-NcCredential` / `Add-NcCredential`
7. Connects to source cluster → detects admin vserver → resolves source volume's node-mgmt LIF
8. If cross-cluster: connects to destination cluster → detects admin vserver → resolves destination volume's node-mgmt LIF → reconnects to source
9. Assembles the `ndmpcopy` command with credentials and LIF-qualified paths
10. Executes via `Invoke-NcSsh` on the source cluster

### Usage Examples

```powershell
# Zero-config — uses NDMP_Config defaults from config.json:
.\scripts\ndmp-copy\Ndmp_Copy.ps1

# Explicit parameters:
.\scripts\ndmp-copy\Ndmp_Copy.ps1 -SrcCluster <src-alias> -DstCluster <dst-alias> `
    -SourcePath "/<src-svm>/<src-vol>/data" -DestPath "/<dst-svm>/<dst-vol>/data"
```

## Batch Wrapper — `scripts/ndmp-copy/ndmp-copy.bat`

A cmd wrapper for `Ndmp_Copy.ps1` — accepts positional arguments or runs zero-config.

```batch
REM Zero-config (all defaults from config.json):
ndmp-copy.bat

REM With positional arguments: SrcCluster DstCluster SourcePath DestPath
ndmp-copy.bat <src-alias> <dst-alias> "/<src-svm>/<src-vol>/<path>" "/<dst-svm>/<dst-vol>/<path>"
```

Runs `pwsh -NoProfile -ExecutionPolicy Bypass` — does not load the workspace profile.

## config.json — NDMP_Config Section

```json
{
  "NDMP_Config": {
    "BackupUser": "backupuser",
    "CredentialPrefix": "ndmp",
    "SrcCluster": "<src-alias>",
    "DstCluster": "<dst-alias>",
    "SRC": "/<src-svm>/<src-vol>/<src-path>",
    "DST": "/<dst-svm>/<dst-vol>/<dst-path>"
  },
  "ONTAP_Clusters": [
    {
      "Alias": "<cluster>",
      "NdmpPassword": "<ndmp-generated-password>",
      "...": "..."
    }
  ]
}
```

## Known Use Cases
| Source | Destination | Path |
|--------|------------|------|
| `<src-cluster>` | `<dst-cluster>` | `/<src-svm>/<src-volume>/<src-path>` → `/<dst-svm>/<dst-volume>/<dst-path>` |
