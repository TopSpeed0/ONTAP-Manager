---
name: ontap-cluster-info
description: 'Gather and display NetApp ONTAP cluster information. Use when: cluster health check, show cluster status, list volumes, list aggregates, list LIFs, list SVMs, cluster inventory, node status, disk info, network info, show ports, show interfaces, SAS diagnostics, shelf health, disk paths, single-path disks, broken disks, storage errors. Quick reconnaissance of cluster state.'
argument-hint: 'Specify what info to gather (e.g., volumes, LIFs, aggregates, SVMs)'
---

# ONTAP Cluster Information Gathering

## When to Use
- Quick health check or status overview of a cluster
- Listing volumes, LIFs, aggregates, SVMs, or nodes
- Checking disk, network, or port information
- Any "show me" or "list" request about the cluster

## Key Concepts (from ONTAP 9 docs)
- **Cluster** = 1-24 nodes (12 for SAN) organized in HA pairs
- **HA pair**: two nodes with automatic takeover/giveback for fault tolerance
- **Aggregate (Local Tier)**: pool of disks assigned to a node; hosts FlexVol/FlexGroup volumes
- **SVM**: virtual server that owns volumes and LIFs; serves data to clients
- **LIF**: logical network endpoint (IP + port) that can migrate between nodes
- Storage hierarchy: Cluster → Nodes → Aggregates → Volumes → LUNs/Files
- Protocols: NFS, SMB/CIFS, iSCSI, FC, NVMe, S3
- For detailed reference, see [ONTAP 9 Cluster Reference](./references/cluster-ontap-reference.md)

## Procedure

### Step 0 — Identify Target Cluster
Ask the user which cluster to query if not specified:
- **<cluster-name>** → use `<cluster-ssh>` or `Get-<Prefix>Csv`
- **<cluster-name>** → use `<cluster-ssh>`

### Common Queries

#### Cluster & Node Info
```powershell
# Cluster identity
<cluster-ssh> -Command "cluster show"

# Node details
Get-<Prefix>Csv -Command "node show -fields node,model,serial-number,uptime,health"

# Cluster health
<cluster-ssh> -Command "system health status show"
```

#### Volume Information
```powershell
Get-<Prefix>Csv -Command "vol show -fields vserver,volume,size,used,percent-used,aggregate,state,type"
```

#### Aggregate Information
```powershell
Get-<Prefix>Csv -Command "aggr show -fields aggregate,size,usedsize,availsize,node,state"
```

#### SVM (Vserver) Information
```powershell
Get-<Prefix>Csv -Command "vserver show -fields vserver,type,state,allowed-protocols,admin-state"
```

#### Network Interfaces (LIFs)
```powershell
Get-<Prefix>Csv -Command "net int show -fields vserver,lif,role,curr-node,curr-port,address,status-oper"
```

#### Network Ports
```powershell
Get-<Prefix>Csv -Command "net port show -fields node,port,link,speed,mtu,health-status"
```

#### Disk Information
```powershell
<cluster-ssh> -Command "disk show -fields disk,type,container-type,position,owner"
```

#### SnapMirror Relationships
```powershell
Get-<Prefix>Csv -Command "snapmirror show -fields source-path,destination-path,state,status,healthy,schedule"
```

#### Snapshot Policies
```powershell
Get-<Prefix>Csv -Command "snapshot policy show -fields policy,enabled,schedule,count"
```

#### Export Policies & Rules
```powershell
Get-<Prefix>Csv -Command "export-policy show -fields vserver,policy"
Get-<Prefix>Csv -Command "export-policy rule show -fields vserver,policyname,clientmatch,protocol,rorule,rwrule"
```

#### LUN Information
```powershell
Get-<Prefix>Csv -Command "lun show -fields vserver,path,size,mapped,serial-number"
```

## SAS / Disk / Shelf Diagnostics

Use `Get-SasDiag` for comprehensive SAS connectivity diagnostics on any cluster.
Script location: `sas-diag.ps1` in the workspace root.

```powershell
# Dot-source to load the function (self-contained, no profile1.ps1 needed)
. .\sas-diag.ps1

# Run on any cluster by alias (console output only)
Get-SasDiag <alias>
Get-SasDiag <alias> -Shelf 2

# Best: export structured JSON (parsed ONTAP fields → proper objects)
Get-SasDiag <alias> -Json          # → <alias>_SAS_diag.json
Get-SasDiag <alias> -Json -Shelf 1  # → <alias>_SAS_diag.json

# Raw text CSV export (legacy)
Get-SasDiag <alias> -Export        # → <alias>_SAS_diag.csv
```

**Prefer `-Json`** — it re-runs each `-fields` command with ONTAP CSV separator and parses into structured objects (proper column names and rows). Non-`-fields` commands store cleaned text lines. The JSON file has: `Cluster`, `Timestamp`, and `Checks` (keyed by step number + name).

### What it checks (11 steps)
1. Storage disk paths (all disks)
2. SAS port status per node
3. Shelf IOM module health
4. Single-path disks
5. Broken / failed disks
6. EMS events — SAS / shelf / IOM errors (last 7d)
7. Active system health alerts
8. SAS error counters
9. Disk path detail (specific shelf or all)
10. Node HW / subsystem status
11. Shelf port detail

### Supported clusters
`a1k`, `nadr`, `nidr`, `<cluster-name>`, `<cluster-name>`, `<cluster-name>`, `<cluster-name>`

The function verifies SSH connectivity before running. No ZAPI / profile dependency.

## Tips
- Use `Get-<Prefix>Csv` to get structured PowerShell objects for filtering and formatting
- Pipe results to `| ft` (Format-Table) for clean console display
- Pipe to `| Where-Object { $_.vserver -eq "svm_name" }` to filter by SVM
- Pipe to `| Export-Csv -Path "output.csv"` to save results
