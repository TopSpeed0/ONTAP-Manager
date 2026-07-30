---
name: iscsi-management
description: 'Manage and troubleshoot ONTAP iSCSI sessions, connections, initiators, and igroups. Use when: iSCSI session show, iSCSI connection show, map IQN to IP address, find initiator remote address, iSCSI initiator show, igroup show, create igroup, add initiator, igroup add, map LUN to igroup, lun map, Proxmox igroup, KVM igroup, linux ostype igroup, iSCSI LIF info, cross-reference session to connection, iSCSI multipath check.'
argument-hint: 'Specify what to check (e.g., sessions, connections, map IQN to IP, igroups)'
---

# ONTAP iSCSI Session & Connection Management

## When to Use
- Show iSCSI sessions, connections, or initiators
- **Map an initiator IQN to its remote IP address** (requires cross-referencing two commands)
- Check iSCSI multipath connectivity
- View igroup membership and LUN mappings
- Troubleshoot iSCSI connectivity issues
- Identify which host (by IP) is behind a given IQN

## Key Concepts

### The IQN-to-IP Problem
ONTAP separates iSCSI session identity (IQN, ISID) from connection details (remote IP).
There is **no single command** that shows both IQN and remote-address together.
You must cross-reference using the composite key **(tpgroup + TSIH)**.

### Join Key: (tpgroup, TSIH)
- **tpgroup** = Target Portal Group (maps 1:1 to an iSCSI LIF)
- **TSIH** = Target Session Identifying Handle (unique per session on a given tpgroup)
- The pair `(tpgroup, TSIH)` uniquely identifies a session across both `iscsi session show` and `vserver iscsi connection show`

### Command Field Reference (verified from CLI)

#### `iscsi session show`
Keys: `-vserver`, `-tpgroup`, `-tsih`
Fields: `-connection-ids`, `-data-pdu-in-order`, `-data-sequence-in-order`, `-default-time-to-retain`, `-default-time-to-wait`, `-error-recovery-level`, `-first-burst-length`, `-immediate-data-enabled`, `-initial-r2t-enabled`, `-initiator-alias`, `-initiator-name`, `-isid`, `-max-burst-length`, `-max-connections`, `-max-ios-per-session`, `-max-outstanding-r2t`, `-session-type`, `-tpgroup-tag`

Has IQN: **YES** (`-initiator-name`). Has remote IP: **NO**.

#### `vserver iscsi connection show`
Keys: `-vserver`, `-tpgroup`, `-tsih`, `-connection-id`
Fields: `-authentication-method`, `-connection-state`, `-data-digest-enabled`, `-has-session`, `-header-digest-enabled`, `-initiator-mrdsl`, `-lif`, `-local-address`, `-local-ip-port`, `-rcv-window-size`, `-remote-address`, `-remote-ip-port`, `-target-mrdsl`, `-tpgroup-tag`

Has IQN: **NO**. Has remote IP: **YES** (`-remote-address`).

#### Why (tpgroup + TSIH) is the only join key
Both commands share keys `-tpgroup` and `-tsih`. Neither command has the other's unique data (IQN vs remote-address). The **only** way to map IQN → IP is to join on `(tpgroup, tsih)`.

#### `iscsi initiator show`
Shows IQN, tpgroup, TSIH, ISID, **and igroup name** in one view. Best single command for initiator identification.

## Procedures

### 1. Quick Overview — All Sessions
```powershell
# All sessions with IQN, alias, tpgroup, TSIH, ISID
<SSH> -Command "iscsi session show -vserver <SVM> -fields tpgroup,tsih,initiator-name,initiator-alias,isid"
```

### 2. Quick Overview — All Connections
```powershell
# Preferred — native cmdlet (returns objects)
Get-NcIscsiConnection -Vserver <SVM>

# Fallback — SSH CLI (all connections with remote/local addresses)
<SSH> -Command "vserver iscsi connection show -vserver <SVM> -fields tpgroup,tsih,remote-address,local-address,remote-ip-port"
```

### 3. Map IQN → Remote IP Address (Cross-Reference)

**Step 1**: Get (tpgroup, TSIH) pairs for the target IQN:
```powershell
# Preferred — native cmdlet: Get-NcIscsiSession -Vserver <SVM> | Where-Object InitiatorName -eq '<IQN>'
# Fallback — SSH CLI:
<SSH> -Command "iscsi session show -vserver <SVM> -initiator-name <IQN> -fields tpgroup,tsih"
```
Example output:
```
vserver          tpgroup                tsih
---------------- ---------------------- ----
<svm>_iscsi <svm>_iscsi_lif_1 1
<svm>_iscsi <svm>_iscsi_lif_2 1
<svm>_iscsi <svm>_iscsi_lif_3 2
<svm>_iscsi <svm>_iscsi_lif_4 2
```

**Step 2**: For each (tpgroup, TSIH) pair, query the connection to get remote-address:
```powershell
# Preferred — native cmdlet: Get-NcIscsiConnection -Vserver <SVM> (filter by tpgroup/tsih)
# Fallback — SSH CLI:
<SSH> -Command "vserver iscsi connection show -vserver <SVM> -tpgroup <TPGROUP> -tsih <TSIH> -fields remote-address,local-address,remote-ip-port"
```

**Step 3**: Present combined results as a table:
| IQN | Alias | tpgroup (LIF) | TSIH | Local Address (LIF IP) | Remote Address (Host IP) |
|-----|-------|---------------|------|------------------------|--------------------------|

### 4. Full Initiator View (IQN + Igroup)
```powershell
# Preferred — native cmdlet
Get-NcIscsiInitiator -Vserver <SVM>

# Fallback — SSH CLI (shows IQN, tpgroup, TSIH, ISID, and igroup name)
<SSH> -Command "iscsi initiator show -vserver <SVM>"
```

### 5. Session Detail (Instance View)
```powershell
# Preferred — native cmdlet (returns objects): Get-NcIscsiSession -Vserver <SVM>
# Fallback — SSH CLI:
<SSH> -Command "iscsi session show -vserver <SVM> -initiator-name <IQN> -instance"
```
Returns: hosting node, tpgroup-tag, ISID, max-burst-length, first-burst-length, connection-ids, etc.

### 6. iSCSI LIF Addresses
```powershell
# Preferred — native cmdlet
Get-NcNetInterface -Vserver <SVM>

# Fallback — SSH CLI
<SSH> -Command "net int show -vserver <SVM> -fields lif,address,curr-node,curr-port,service-policy"
```

### 7. Igroup Configuration
```powershell
# Preferred — native cmdlet
Get-NcIgroup -Vserver <SVM>

# Fallback — SSH CLI
<SSH> -Command "igroup show -vserver <SVM> -fields igroup,protocol,ostype"
```

### 8. PowerShell Automation — Map All IQNs to IPs

For automated cross-referencing across all initiators, use this PowerShell approach:

```powershell
# Preferred — native cmdlets return objects directly (no text parsing):
#   $sessions    = Get-NcIscsiSession -Vserver <SVM>
#   $connections = Get-NcIscsiConnection -Vserver <SVM>
# Join on (tpgroup, TSIH). The SSH + Get-<Prefix>Csv parsing below is the fallback.

# Step 1: Get all sessions
$sessions = <SSH> -Command "iscsi session show -vserver <SVM> -fields tpgroup,tsih,initiator-name,initiator-alias,isid" | 
    # Parse the output into objects (use Get-<Prefix>Csv pattern for <cluster-name>)

# Step 2: Get all connections  
$connections = <SSH> -Command "vserver iscsi connection show -vserver <SVM> -fields tpgroup,tsih,remote-address,local-address" |
    # Parse similarly

# Step 3: Join on (tpgroup, TSIH)
# Match each session to its connection by tpgroup + tsih
```

### 9. Provision an igroup for Linux hosts (Proxmox / KVM / RHEL / Debian)

Use **`-ostype linux`** for Proxmox, KVM, RHEL, and Debian initiators (VMware hosts use `-ostype vmware`).
Collect each host's IQN first (`cat /etc/iscsi/initiatorname.iscsi` on the host).

```powershell
# 1. Create the igroup (iSCSI protocol, linux ostype)
<cluster-s> "igroup create -vserver <SVM> -igroup <IgroupName> -protocol iscsi -ostype linux"

# 2. Add all initiators in one call (comma-separated, no spaces)
<cluster-s> "igroup add -vserver <SVM> -igroup <IgroupName> -initiator <iqn1>,<iqn2>,<iqn3>"

# 3. Verify membership
<cluster-s> "igroup show -vserver <SVM> -igroup <IgroupName> -instance"
```

Notes:
- Newly added initiators show **`(not logged in)`** until the host establishes an iSCSI session and a LUN is mapped — this is expected.
- ALUA is enabled by default on the igroup — leave it on for multipath.
- One igroup can hold hosts from multiple physical sites; group by the LUN/datastore they will share, not by location.

### 10. Map a LUN to the igroup (Linux thin LUN)

```powershell
# Map an existing LUN to the igroup (LUN ID auto-assigned, or use -lun-id)
<cluster-s> "lun map -vserver <SVM> -path /vol/<vol>/<lun> -igroup <IgroupName>"

# Verify the mapping (igroup + assigned LUN ID)
<cluster-s> "lun mapping show -vserver <SVM> -path /vol/<vol>/<lun> -fields igroup,lun-id"
```

LUN provisioning checklist for Linux hosts:
- **OS Type** = `linux` on the LUN as well as the igroup.
- **Space Allocation = enabled** (`lun modify -space-allocation enabled`) so the host can reclaim freed blocks via SCSI UNMAP/TRIM on a thin LUN.
- **Space Reservation = disabled** for thin-on-thin (matches a `space-guarantee none` volume).
- See volume-management skill for SAN volume space management (snapshot autodelete when autosize is off).

## LIF-to-tpgroup Mapping (<cluster-name> reference)

| tpgroup | LIF IP | Node | Port | VLAN |
|---------|--------|------|------|------|
| <svm>_iscsi_lif_1 | <iscsi-lif-ip> | <node-01> | a0b-3005 | iSCSI dedicated |
| <svm>_iscsi_lif_2 | <iscsi-lif-ip> | <node-02> | a0b-3005 | iSCSI dedicated |
| <svm>_iscsi_lif_3 | <iscsi-lif-ip> | <node-01> | a0a-3003 | data network |
| <svm>_iscsi_lif_4 | <iscsi-lif-ip> | <node-02> | a0a-3003 | data network |

## Important Notes
- `node` is **not a valid `-fields` argument** for session or connection show; use `-instance` to see hosting node
- `initiator-name` is always displayed in session show output (not a `-fields` option, it's a default column)
- `iscsi initiator show` is the most comprehensive single command — shows IQN, igroup, tpgroup, TSIH, ISID all at once
- Each initiator typically has 4 sessions (one per LIF) for full multipath coverage
- `initiator-mrdsl` (262144 = 256KB) and `target-mrdsl` (65536 = 64KB) indicate MaxRecvDataSegmentLength negotiated values
