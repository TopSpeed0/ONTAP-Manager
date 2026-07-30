# SVM Management Reference — From ONTAP 9 Documentation

## Storage Virtual Machines (SVMs) Overview

An SVM is a logical entity that abstracts physical resources. Like a virtual machine on a hypervisor:
- Data accessed through the SVM is NOT bound to a physical storage location
- Network access is NOT bound to a physical port
- Volumes can be assigned to any data aggregate in the cluster
- LIFs can be hosted by any physical or logical port
- Both volumes and LIFs can be moved without disrupting data service

SVMs were formerly called **"vservers"**. The ONTAP CLI still uses the term `vserver`.

## SVM Types

| Type | Purpose | Created By |
|------|---------|------------|
| **Data SVM** | Serves data to clients | Cluster admin |
| **Admin SVM** | Cluster administration | Auto-created at cluster setup |
| **Node SVM** | Node-level communication | Auto-created when node joins cluster |
| **System SVM** | Cluster-level communication within an IPspace | Auto-created |

Only data SVMs serve client data. Admin, Node, and System SVMs cannot be used for data serving.

## SVM Subtypes

| Subtype | Purpose |
|---------|---------|
| `default` | Normal data-serving SVM |
| `dp-destination` | SVM DR destination (receives SnapMirror replication) |
| `sync-source` | MetroCluster source |
| `sync-destination` | MetroCluster destination |

## Namespaces and Junction Points

- Each SVM has a **unique namespace** — a file system hierarchy
- The SVM **root volume** is the entry point to the namespace
- Volumes are mounted at **junction points** to build the namespace tree
- Junction paths support nested directories: `/vol1/vol2/vol3` or `/dir1/dir2/vol3`
- Clients mount NFS exports or access SMB shares without knowing physical storage location

## SVM Creation Requirements

### Aggregate Selection
- Must have at least **1 GB** free space for root volume
- If NAS auditing is planned: minimum **3 GB** extra free space on root aggregate
- Choose non-root aggregates for data volume placement

### CLI: Create SVM
```
vserver create -vserver <name> -aggregate <aggr> -rootvolume <root_vol_name> -rootvolume-security-style {unix|ntfs|mixed} [-ipspace <IPspace>] [-language <lang>] [-snapshot-policy <policy>]
```

### CLI: SVM for SVM-DR (Destination)
```
vserver create -vserver <name> -subtype dp-destination
```

## SVM Capacity (ONTAP 9.13.1+)
- Can set **maximum capacity** for an SVM
- Configure alerts when approaching threshold capacity level

## Protocol Configuration

### Security Style
| Style | When to Use |
|-------|------------|
| `unix` | NFS-only or mixed NFS/SMB environments with UNIX permissions |
| `ntfs` | SMB-only or Hyper-V/SQL Server over SMB |
| `mixed` | Both NFS and SMB with mixed permission models |

### Protocol Setup Order
1. Create SVM with root volume
2. Configure allowed protocols (`vserver modify -allowed-protocols`)
3. Create data LIFs for chosen protocols
4. Configure protocol services (NFS/CIFS/iSCSI)
5. Set up DNS and name services
6. Create export policies (NFS) or shares (SMB)
7. Create data volumes and mount at junction points

## Cluster and SVM Administrators

| Admin Type | Scope | Default Role |
|-----------|-------|-------------|
| Cluster admin | Entire cluster and all resources | `admin` |
| SVM admin | Single data SVM | `vsadmin` |

## RBAC (Role-Based Access Control)
- Roles control which commands an administrator can access
- Assigned at account creation
- Custom roles can be defined
- SVM admins can be restricted to specific operations

## Key CLI Commands

### List SVMs
```
vserver show -fields vserver,type,state,allowed-protocols,admin-state,subtype
```

### Modify Allowed Protocols
```
vserver modify -vserver <name> -allowed-protocols nfs,cifs,iscsi
```

### Set SVM Max Capacity (ONTAP 9.13.1+)
```
vserver modify -vserver <name> -storage-limit <size> -storage-limit-threshold-alert <percent>
```

### Delete SVM (requires all volumes and LIFs removed first)
```
vserver delete -vserver <name>
```
