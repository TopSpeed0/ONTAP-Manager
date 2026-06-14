---
name: network-management
description: 'Manage NetApp ONTAP networking. Use when: creating LIF, modifying LIF, broadcast domain, failover group, routes, DNS, subnet, VLAN, ifgrp, port configuration, network troubleshooting, intercluster LIF, check connectivity, ping from node.'
argument-hint: 'Specify operation (create LIF, show ports, etc.) and target cluster'
---

# Network Management

## When to Use
- Creating or modifying logical interfaces (LIFs)
- Troubleshooting network connectivity
- Managing broadcast domains, VLANs, ifgrps
- Configuring routes, DNS, subnets

## Key Concepts (from ONTAP 9 docs)
- **LIF**: IP address + port assignment that can migrate between nodes non-disruptively
- **ONTAP 9.6+**: `-role` parameter is deprecated — use `-service-policy` instead
- **NAS LIFs** auto-failover to surviving ports; **SAN LIFs** do NOT (host uses ALUA + MPIO)
- **Broadcast domains** group ports in the same L2 network; auto-create failover groups
- **Subnets** reserve IP blocks in a broadcast domain — simpler than manual IP+mask per LIF
- **IPspaces** isolate network traffic (multitenant, replication isolation)
- Intercluster LIFs require ports **11104** and **11105** open (bidirectional TCP) + HTTPS
- Failover policies: `system-defined`, `local-only`, `sfo-partner-only`, `broadcast-domain-wide`
- For detailed reference, see [ONTAP 9 Network Reference](./references/network-ontap-reference.md)

## Common Queries

### Show Network Interfaces (LIFs)
```powershell
Get-ProdCsv -Command "net int show -fields vserver,lif,role,curr-node,curr-port,address,netmask,status-oper,data-protocol"
```

### Show Network Ports
```powershell
Get-ProdCsv -Command "net port show -fields node,port,link,speed,mtu,health-status,broadcast-domain"
```

### Show Broadcast Domains
```powershell
Get-ProdCsv -Command "net port broadcast-domain show -fields broadcast-domain,mtu,ipspace,ports"
```

### Show Routes
```powershell
Get-ProdCsv -Command "net route show -fields vserver,destination,gateway,metric"
```

### Show Failover Groups
```powershell
Get-ProdCsv -Command "net int failover-groups show -fields failover-group,vserver,targets"
```

## LIF Operations

### Create a Data LIF
```powershell
Prod-s -Command "net int create -vserver <svm> -lif <lif_name> -role data -data-protocol <nfs|cifs|iscsi> -home-node <node> -home-port <port> -address <ip> -netmask <mask>"
```

### Modify a LIF
```powershell
Prod-s -Command "net int modify -vserver <svm> -lif <lif_name> -address <_ip> -netmask <mask>"
```

### Migrate a LIF
```powershell
Prod-s -Command "net int migrate -vserver <svm> -lif <lif_name> -dest-node <node> -dest-port <port>"
```

### Revert a LIF to Home
```powershell
Prod-s -Command "net int revert -vserver <svm> -lif <lif_name>"
```

## VLAN and Ifgrp

### Create VLAN
```powershell
Prod-s -Command "net port vlan create -node <node> -vlan-name <port>-<vlan-id>"
```

### Create Interface Group
```powershell
Prod-s -Command "net port ifgrp create -node <node> -ifgrp <ifgrp_name> -mode multimode_lacp -distr-func ip"
Prod-s -Command "net port ifgrp add-port -node <node> -ifgrp <ifgrp_name> -port <port>"
```

## Troubleshooting

### Ping from Node
```powershell
Prod-s -Command "net ping -node <node> -destination <ip> -vrf <ipspace>"
```

### Check LIF Status
```powershell
Get-ProdCsv -Command "net int show -fields lif,status-oper,status-admin,is-home,curr-node,curr-port"
```

## Safety
- Always confirm before modifying network configurations
- Verify port and node names before creating LIFs
- Check current broadcast domain assignments before making changes
