# Network Management Reference — From ONTAP 9 Documentation

## ONTAP Networking Components

### Logical Interfaces (LIFs)
A LIF is an IP address or WWPN associated with a port. It represents a network access point to the cluster. LIFs can be moved between ports and nodes without disruption.

### LIF Types and Service Policies

| LIF Type / Role | Purpose | Service Policy |
|-----------------|---------|---------------|
| Data LIF | NAS/SAN client data access | `default-data-files`, `default-data-iscsi` |
| Cluster LIF | Intra-cluster traffic | `default-cluster` |
| Intercluster LIF | Cross-cluster replication | `default-intercluster` |
| Node Management LIF | Node administration | `default-management` |
| Cluster Management LIF | Cluster-wide administration | `default-management` |

**Important**: Beginning with ONTAP 9.6, the `role` parameter is deprecated. Use `-service-policy` instead. The `role` parameter still works for backward compatibility.

### IPspaces
- Logical grouping of network resources for tenant isolation
- Each IPspace has its own routing table, broadcast domains, and IP addresses
- Custom IPspaces isolate replication traffic in multitenant environments
- Default IPspace: `Default` (used for most data traffic)
- Cluster IPspace: `Cluster` (used for cluster interconnect)

### Broadcast Domains
- Group ports that belong to the same Layer 2 network
- Each broadcast domain belongs to an IPspace
- ONTAP auto-creates failover groups matching broadcast domains
- Best practice: use broadcast domains to define failover groups

### Subnets
- Reserve a block of IP addresses in a broadcast domain
- Allocated to LIFs when created
- Easier and less error-prone than specifying IP+mask manually
- Specify subnet name when defining a LIF address

## NAS Path Failover
- NAS LIFs **automatically migrate** to a surviving port after link failure
- Target port must be in the LIF's failover group
- Default failover policy: ports on owning node + HA partner

## SAN Path Failover
- SAN LIFs do **NOT** migrate automatically
- Host uses **ALUA** (Asymmetric Logical Unit Access) + **MPIO** (Multipath I/O) to reroute
- Configure multiple optimized paths on owning node + non-optimized paths on HA partner

## LIF Failover Policies

| Policy | Failover Targets | Best For |
|--------|-----------------|----------|
| `system-defined` | HA partner nodes, then other nodes | General data LIFs |
| `local-only` | Same node only | Management LIFs |
| `sfo-partner-only` | HA partner only | Intercluster LIFs |
| `broadcast-domain-wide` | All ports in broadcast domain | Wide failover coverage |

## Port Configuration

### Dedicated vs Shared Ports for Intercluster
- **High-speed network (10 GbE+)**: Can share ports with data traffic
- **Replication during off-peak**: Safe to share data ports
- **Data utilization >50%**: Use dedicated ports
- VLAN ports can be used to dedicate bandwidth for replication
- MTU should be consistent across all intercluster ports

### Firewall / Service Policy Requirements
- Bidirectional ICMP traffic
- Bidirectional TCP on ports **11104** and **11105**
- Bidirectional HTTPS between intercluster LIFs
- Beginning ONTAP 9.10.1: firewall policies replaced by LIF service policies

## Key CLI Commands

### Create LIF
```
network interface create -vserver <svm> -lif <name> -service-policy <policy> -home-node <node> -home-port <port> -address <ip> -netmask <mask>
```

### Create LIF with Subnet
```
network interface create -vserver <svm> -lif <name> -service-policy <policy> -home-node <node> -home-port <port> -subnet-name <subnet>
```

### Modify LIF Failover
```
network interface modify -vserver <svm> -lif <name> -failover-policy <policy> -failover-group <group>
```

### Create Intercluster LIF
```
network interface create -vserver <cluster_name> -lif <ic_lif> -service-policy default-intercluster -home-node <node> -home-port <port> -address <ip> -netmask <mask>
```

### Check Port Reachability
```
network port reachability show -detail -node <node> -port <port>
```

### Repair Port Reachability
```
network port reachability repair -node <node> -port <port>
```

### Verify Service Policy
```
network interface service-policy show -policy default-intercluster
```
