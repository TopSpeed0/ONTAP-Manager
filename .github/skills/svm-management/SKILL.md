---
name: svm-management
description: 'Create and manage NetApp Storage Virtual Machines (SVMs / Vservers). Use when: creating SVM, configuring SVM, setting up NFS, setting up CIFS, setting up iSCSI, SVM protocols, export policies, configuring data LIFs, vserver configuration, NAS setup, SAN setup.'
argument-hint: 'Specify operation (create, modify, configure protocols) and SVM details'
---

# SVM (Storage Virtual Machine) Management

## When to Use
- Creating a new SVM with NAS or SAN protocols
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
- ONTAP 9.13.1+: can set **max capacity** and threshold alerts on SVMs
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
# Preferred — native NetApp.ONTAP cmdlet
Get-NcVserver
# Fallback — only if Get-NcVserver is unavailable
Get-<Prefix>Csv -Command "vserver show -fields vserver,type,state,allowed-protocols,admin-state"
```

### Create an SVM
```powershell
<cluster-ssh> -Command "vserver create -vserver <svm_name> -rootvolume <root_vol> -rootvolume-security-style unix -aggregate <aggr>"
```

### Configure Allowed Protocols
```powershell
<cluster-ssh> -Command "vserver modify -vserver <svm_name> -allowed-protocols nfs,cifs"
```

### Create Data LIFs
```powershell
# NFS/CIFS data LIF
<cluster-ssh> -Command "net int create -vserver <svm_name> -lif <lif_name> -role data -data-protocol nfs,cifs -home-node <node> -home-port <port> -address <ip> -netmask <mask>"

# iSCSI data LIF
<cluster-ssh> -Command "net int create -vserver <svm_name> -lif <lif_name> -role data -data-protocol iscsi -home-node <node> -home-port <port> -address <ip> -netmask <mask>"
```

### Configure NFS
```powershell
# Create NFS service
<cluster-ssh> -Command "nfs create -vserver <svm_name> -v3 enabled -v4.0 enabled -v4.1 enabled"

# Verify
<cluster-ssh> -Command "nfs show -vserver <svm_name>"
```

### Configure CIFS
```powershell
# Preferred - native cmdlet. Asynchronous: returns a JobStartResult, NOT the result.
$cred = New-Object System.Management.Automation.PSCredential('<admin-account>', $securePassword)
Add-NcCifsServer -Name <cifs_name> -Domain <ad_fqdn> `
    -OrganizationalUnit '<ou-path-without-DC-components>' `
    -AdminCredential $cred -AdministrativeStatus up -VserverContext <svm_name>

# Fallback - CLI. Prompts interactively for the AD username and password.
<cluster-ssh> -Command "vserver cifs create -vserver <svm_name> -cifs-server <cifs_name> -domain <ad_fqdn> -ou <ou_path>"

# Verify
Get-NcCifsServer -VserverContext <svm_name>
```

Pass the OU to ONTAP **without** the `DC=` components - ONTAP appends the domain.
Keep the site's actual OU path in local notes, not in this tracked file.

#### CIFS join pitfalls - read before debugging a failed join

**1. Never pass the join account with a NetBIOS prefix.** `<NETBIOS>\<admin-account>` makes
ONTAP treat `<NETBIOS>` as the *Kerberos realm*, so the SRV lookup for
`_kerberos._tcp.<NETBIOS>` finds nothing and the join dies before it ever reaches AD:

```
**FAILURE: Could not authenticate as '<admin-account>@<NETBIOS>':
**         Cannot find KDC for requested realm (KRB5_REALM_UNKNOWN)
```

Use the bare SAM name (`<admin-account>`) or the UPN (`<admin-account>@<domain-fqdn>`) and
let `-Domain <ad_fqdn>` supply the realm. A stored-credential helper typically returns the
NetBIOS-prefixed form, so rebuild the credential before passing it:

```powershell
$cred = New-Object System.Management.Automation.PSCredential('<admin-account>', $raw.Password)
```

**2. `Add-NcCifsServer` does not throw on failure.** It returns a `JobStartResult`; the
real outcome lands in the job. A create that looked successful at the cmdlet is routinely
a failed job. Always confirm, and read the reason from the job or EMS:

```powershell
Get-NcCifsServer -VserverContext <svm_name>
Get-NcJob -VserverContext <svm_name> | Select-Object JobState, JobCompletion
Get-NcEmsMessage -Severity emergency,alert,error |
    Where-Object { $_.Event -match '<svm_name>' } | Sort-Object TimeDT -Descending
```

**3. "Created a machine account" followed by an LSA timeout is a firewall/L7 problem, not AD.**

```
[nnnnn] Created a machine account in the domain                 <- LDAP 389 + Kerberos 88 OK
[nnnnn] Successfully connected to ip <dc>, port 445 using TCP   <- 445 is ALREADY OPEN
[nnnnn] Unable to connect to LSA service on <dc> (RESULT_ERROR_SPINCLIENT_COMMAND_TIMED_OUT)
**      FAILURE: Unable to make a connection (LSA:<DOMAIN>),
**              Result: RESULT_ERROR_SECD_NO_CONNECTIONS_AVAILABLE
[nnnnn] Deleted existing account 'CN=...'                       <- ONTAP rolls back cleanly
```

The TCP handshake completing proves **port 445 is already permitted** - do not raise a
ticket asking for it. What is dropped is the MSRPC/SMB traffic *inside* the established
session: an App-ID / L7 policy that does not yet know the new data LIF's source IP. The
~3000 ms gap is ONTAP's LSA timeout expiring with no response at all (a closed port would
RST immediately).

Get the firewall traffic log for `src <lif_ip> -> dst <dc_ip>` at the time of the attempt;
it names the matching rule and the denied App-ID (`msrpc`, `ms-ds-smb`, `netbios-ss`).
Frame the request as "grant `<new_lif_ip>` the same DC access that `<working_lif_ip>` on
the same subnet already has" rather than guessing at a port list.

ONTAP deletes the machine account it created when the join fails, so retries are safe and
leave no orphan AD object. Verify with `Get-ADComputer -Filter "Name -eq '<cifs_name>'"`.

**4. An already-joined SVM on the same cluster is not proof the path is open.** A
transitioned or migrated SVM carries its machine account and secure channel with it and
never performs a join from its current network. Check the AD computer object before
treating it as a working reference:

```powershell
Get-ADComputer -Identity <cifs_name> -Server <domain> `
    -Properties whenCreated, pwdLastSet, lastLogonTimestamp, OperatingSystem |
  Select-Object Name, DistinguishedName, OperatingSystem, whenCreated,
    @{n='pwdLastSet';e={[datetime]::FromFileTime($_.pwdLastSet)}},
    @{n='lastLogon';e={[datetime]::FromFileTime($_.lastLogonTimestamp)}}
```

If `OperatingSystem` names an ONTAP release older than the cluster it now runs on, that
SVM joined somewhere else and tells you nothing about the current firewall posture. A
stale `pwdLastSet` means it is coasting on a secure channel established under an older
policy - it may hit the same wall if it ever re-joins or starts rotating.

**5. Comparing against a working SVM.** Check LIF node/port and `IsHome`, broadcast
domain, route, SVM DNS (`Get-NcNetDns`) and ns-switch. Two traps:
`Get-NcCifsDomainServer` **ignores `-VserverContext`** and returns the same table whatever
you pass - check the `Vserver` UUID in its output before trusting it. And
`Invoke-NcNetInterfaceRevert` can silently no-op; use
`Move-NcNetInterface -DestinationNode <node> -DestinationPort <port>` to place a LIF
deterministically.

**6. Workgroup mode needs no DC at all.** If the SVM only has to serve SMB shares in a lab
and does not need AD identity, a non-domain CIFS server sidesteps the whole LSA path and
works with zero firewall change.

### Configure iSCSI
```powershell
# Create iSCSI service
<cluster-ssh> -Command "iscsi create -vserver <svm_name>"

# Verify
<cluster-ssh> -Command "iscsi show -vserver <svm_name>"
```

### Export Policies
```powershell
# Create export policy
<cluster-ssh> -Command "export-policy create -vserver <svm_name> -policyname <policy_name>"

# Add rule
<cluster-ssh> -Command "export-policy rule create -vserver <svm_name> -policyname <policy_name> -clientmatch <cidr_or_host> -protocol nfs -rorule sys -rwrule sys -superuser sys"

# Show rules
# Preferred — native cmdlet
Get-NcExportRule -Vserver <svm_name>
# Fallback — only if Get-NcExportRule is unavailable
Get-<Prefix>Csv -Command "export-policy rule show -vserver <svm_name> -fields policyname,clientmatch,protocol,rorule,rwrule"
```

### DNS Configuration
```powershell
<cluster-ssh> -Command "dns create -vserver <svm_name> -domains <domain> -name-servers <dns_ip1>,<dns_ip2>"
```

### Delete SVM
**WARNING:** Confirm with user before running. All volumes and LIFs must be removed first.
```powershell
<cluster-ssh> -Command "vserver delete -vserver <svm_name>"
```

## Safety
- Never delete an SVM without explicit user confirmation
- Verify all volumes are removed or moved before SVM deletion
- Confirm CIFS domain credentials with user before AD join operations
