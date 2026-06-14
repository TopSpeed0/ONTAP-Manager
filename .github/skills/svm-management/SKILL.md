---
name: svm-management
description: 'Create and manage NetApp Storage Virtual Machines (SVMs / Vservers). Use when: creating SVM, configuring SVM, setting up NFS, setting up CIFS, setting up iSCSI, SVM protocols, export policies, configuring data LIFs, vserver configuration, NAS setup, SAN setup.'
argument-hint: 'Specify operation (create, modify, configure protocols) and SVM details'
---

# SVM (Storage Virtual Machine) Management

## When to Use
- Creating a  SVM with NAS or SAN protocols
- Configuring data LIFs on an SVM
- Setting up NFS, CIFS, or iSCSI services
- Managing export policies and rules

## Key Concepts (from ONTAP 9 docs)
- **SVM** (formerly "vserver"): logical entity abstracting physical resources — like a VM on a hypervisor
- SVM types: `data` (serves clients), `admin` (cluster mgmt), `node`, `system`
- SVM subtypes: `default` (normal), `dp-destination` (SVM-DR target)
- Each SVM has a **unique namespace** built from volumes mounted at junction points
- Root volume = entry point to namespace; needs ≥1 GB space (≥3 GB if NAS auditing)
- Security styles: `unix` (NFS), `ntfs` (SMB/Hyper-V), `mixed` (multi-protocol)
- ONTAP 9.13.1+: can set **max capacity** and thresh alerts on SVMs
- SVM admin role: `vsadmin` (can create custom RBAC roles)
- For detailed reference, see [ONTAP 9 SVM Reference](./references/svm-ontap-reference.md)

## Procedure

### Step 0 — Gather Requirements
Ask the user:
1. **Cluster** to create the SVM on
2. **SVM name**
3. **Protocols**: NFS, CIFS, iSCSI, or a combination
4. **Network**: IP addresses for data LIFs, subnet, home nodes/ports
5. **Root aggregate** and **volume** configuration

### List Existing SVMs
```powershell
Get-ProdCsv -Command "vserver show -fields vserver,type,state,allowed-protocols,admin-state"
```

### Create an SVM
```powershell
Prod-s -Command "vserver create -vserver <svm_name> -rootvolume <root_vol> -rootvolume-security-style unix -aggregate <aggr>"
```

### Configure Allowed Protocols
```powershell
Prod-s -Command "vserver modify -vserver <svm_name> -allowed-protocols nfs,cifs"
```

### Create Data LIFs
```powershell
# NFS/CIFS data LIF
Prod-s -Command "net int create -vserver <svm_name> -lif <lif_name> -role data -data-protocol nfs,cifs -home-node <node> -home-port <port> -address <ip> -netmask <mask>"

# iSCSI data LIF
Prod-s -Command "net int create -vserver <svm_name> -lif <lif_name> -role data -data-protocol iscsi -home-node <node> -home-port <port> -address <ip> -netmask <mask>"
```

### Configure NFS
```powershell
# Create NFS service
Prod-s -Command "nfs create -vserver <svm_name> -v3 enabled -v4.0 enabled -v4.1 enabled"

# Verify
Prod-s -Command "nfs show -vserver <svm_name>"
```

### Configure CIFS
```powershell
# Create CIFS server (joins AD)
Prod-s -Command "cifs create -vserver <svm_name> -cifs-server <cifs_name> -domain <ad_domain> -ou <ou_path>"

# Verify
Prod-s -Command "cifs show -vserver <svm_name>"
```

### Configure iSCSI
```powershell
# Create iSCSI service
Prod-s -Command "iscsi create -vserver <svm_name>"

# Verify
Prod-s -Command "iscsi show -vserver <svm_name>"
```

### Export Policies
```powershell
# Create export policy
Prod-s -Command "export-policy create -vserver <svm_name> -policyname <policy_name>"

# Add rule
Prod-s -Command "export-policy rule create -vserver <svm_name> -policyname <policy_name> -clientmatch <cidr_or_host> -protocol nfs -rorule sys -rwrule sys -superuser sys"

# Show rules
Get-ProdCsv -Command "export-policy rule show -vserver <svm_name> -fields policyname,clientmatch,protocol,rorule,rwrule"
```

### DNS Configuration
```powershell
Prod-s -Command "dns create -vserver <svm_name> -domains <domain> -name-servers <dns_ip1>,<dns_ip2>"
```

### Delete SVM
**WARNING:** Confirm with user before running. All volumes and LIFs must be removed first.
```powershell
Prod-s -Command "vserver delete -vserver <svm_name>"
```

## Safety
- Never delete an SVM without explicit user confirmation
- Verify all volumes are removed or moved before SVM deletion
- Confirm CIFS domain credentials with user before AD join operations
