# ONTAP Cluster Information Reference — From ONTAP 9 Documentation

## Cluster Architecture

### Nodes and HA Pairs
- **Nodes** = controller + storage + network connectivity + ONTAP instance
- Nodes are paired in **HA pairs** for fault tolerance and non-disruptive operations
- Cluster limits: up to **12 nodes for SAN**, up to **24 nodes for NAS**
- HA pair nodes must use the **same storage array model**
- Nodes communicate over a private dedicated **cluster interconnect**

### When a Node Fails
- Its HA partner **takes over** storage and continues serving data
- Partner **gives back** storage when the node comes back online
- This is called **takeover** and **giveback**

## ONTAP Platforms

| Platform | Description |
|----------|-------------|
| AFF (All Flash FAS) | Flash-optimized storage systems |
| ASA (All SAN Array) | SAN-only optimized systems |
| FAS | Hybrid (flash + HDD) storage systems |
| ONTAP Select | Software-defined on commodity hardware |
| Cloud Volumes ONTAP | ONTAP in public cloud (AWS, Azure, GCP) |

## Storage Hierarchy

```
Cluster
├── Node(s) (HA Pairs)
│   ├── Aggregates (Local Tiers)
│   │   ├── Disks / SSDs
│   │   └── FlexVol / FlexGroup Volumes
│   │       ├── LUNs (SAN)
│   │       ├── Qtrees
│   │       └── Files (NAS)
│   └── Network Ports
│       └── LIFs (Logical Interfaces)
└── SVMs (Storage Virtual Machines)
    ├── Volumes (junction paths → namespace)
    ├── LIFs (data, management)
    └── Protocol services (NFS, CIFS, iSCSI, FC)
```

## Key Object Types

| Object | Description | CLI Show Command |
|--------|-------------|-----------------|
| Cluster | Top-level container | `cluster show` |
| Node | Physical controller | `node show` |
| Aggregate (Local Tier) | Pool of disks | `aggr show` |
| SVM (Vserver) | Virtual server for data | `vserver show` |
| Volume | Logical storage unit | `vol show` |
| LIF | Network endpoint | `net int show` |
| LUN | Block device for SAN | `lun show` |
| Qtree | Sub-volume partition | `qtree show` |
| SnapMirror | Replication relationship | `snapmirror show` |
| Snapshot | Point-in-time copy | `snapshot show` |

## AutoSupport
- Proactive health monitoring that sends data to NetApp
- Checks system health and configuration
- Required for proactive support cases

## Health Monitoring

### System Health Monitors
```
system health status show        # Overall cluster health
system health alert show         # Active alerts
system health subsystem show     # Subsystem health status
```

### Key Health Check Commands
```
# Cluster identity and status
cluster show
cluster identity show
system node show

# Storage health
aggr show -fields aggregate,size,usedsize,availsize,state
disk show -broken

# Network health
net int show -fields lif,status-oper,is-home
net port show -fields node,port,link,health-status

# Failover status
storage failover show

# SnapMirror health
snapmirror show -fields healthy,status,lag-time

# License status
system license show
```

## QoS (Quality of Service)

### Throughput Ceilings (Max)
```
qos policy-group create -policy-group <name> -vserver <svm> -max-throughput <iops|mbps>
```

### Throughput Floors (Min)
```
qos policy-group create -policy-group <name> -vserver <svm> -min-throughput <iops>
```

## FabricPool (Cloud Tiering)
- Automatically tiers cold data to cloud storage (S3, Azure Blob, etc.)
- Tiering policies: `none`, `snapshot-only`, `auto`, `all`
- Source volumes on FabricPool aggregates replicate to FabricPool on destination

## Client Protocols

| Protocol | Use Case | LIF Type |
|----------|----------|----------|
| NFS (v3, v4.x) | Linux/UNIX file access | Data LIF with `nfs` data-protocol |
| SMB/CIFS (2.x, 3.x) | Windows file access | Data LIF with `cifs` data-protocol |
| iSCSI | Block storage over IP | Data LIF with `iscsi` data-protocol |
| FC | Block storage over Fibre Channel | FC LIF |
| NVMe/FC, NVMe/TCP | High-performance block | NVMe LIF |
| S3 | Object storage | S3 LIF |
