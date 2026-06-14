---
name: iscsi-management
description: 'Manage and troubleshoot ONTAP iSCSI sessions, connections, initiators, and igroups. Use when: iSCSI session show, iSCSI connection show, map IQN to IP address, find initiator remote address, iSCSI initiator show, igroup show, iSCSI LIF info, cross-reference session to connection, iSCSI multipath check.'
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
# All connections with remote/local addresses
<SSH> -Command "vserver iscsi connection show -vserver <SVM> -fields tpgroup,tsih,remote-address,local-address,remote-ip-port"
```

### 3. Map IQN → Remote IP Address (Cross-Reference)

**Step 1**: Get (tpgroup, TSIH) pairs for the target IQN:
```powershell
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
<SSH> -Command "vserver iscsi connection show -vserver <SVM> -tpgroup <TPGROUP> -tsih <TSIH> -fields remote-address,local-address,remote-ip-port"
```

**Step 3**: Present combined results as a table:
| IQN | Alias | tpgroup (LIF) | TSIH | Local Address (LIF IP) | Remote Address (Host IP) |
|-----|-------|---------------|------|------------------------|--------------------------|

### 4. Full Initiator View (IQN + Igroup)
```powershell
# Shows IQN, tpgroup, TSIH, ISID, and igroup name
<SSH> -Command "iscsi initiator show -vserver <SVM>"
```

### 5. Session Detail (Instance View)
```powershell
<SSH> -Command "iscsi session show -vserver <SVM> -initiator-name <IQN> -instance"
```
Returns: hosting node, tpgroup-tag, ISID, max-burst-length, first-burst-length, connection-ids, etc.

### 6. iSCSI LIF Addresses
```powershell
<SSH> -Command "net int show -vserver <SVM> -fields lif,address,curr-node,curr-port,service-policy"
```

### 7. Igroup Configuration
```powershell
<SSH> -Command "igroup show -vserver <SVM> -fields igroup,protocol,ostype"
```

### 8. PowerShell Automation — Map All IQNs to IPs

For automated cross-referencing across all initiators, use this PowerShell approach:

```powershell
# Step 1: Get all sessions
$sessions = <SSH> -Command "iscsi session show -vserver <SVM> -fields tpgroup,tsih,initiator-name,initiator-alias,isid" | 
    # Parse the output into objects (use Get-<Prefix>Csv pattern for <cluster-name>)

# Step 2: Get all connections  
$connections = <SSH> -Command "vserver iscsi connection show -vserver <SVM> -fields tpgroup,tsih,remote-address,local-address" |
    # Parse similarly

# Step 3: Join on (tpgroup, TSIH)
# Match each session to its connection by tpgroup + tsih
```

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
