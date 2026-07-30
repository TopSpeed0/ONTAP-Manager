# SolidFire Node Offline Due to BMC/IPMI Communication Issue — Known Issue

## Symptoms
- SolidFire alert reports **Node Offline** (e.g., nodeID=2)
- Master service not responding on the affected node
- Fan / sensor-related anomalies reported by the node
- Node becomes unreachable and is marked offline within the HCI cluster

## Environment
- NetApp SolidFire / NetApp HCI
- Element OS versions prior to 12.3.1
- H-Series storage nodes

## Root Cause
- **BMC / IPMI communication problems** cause the node to be marked offline
- Fan / sensor errors were known issues in affected Element software versions
- Element 12.3 introduced improvements, but the **fan-related issue is fully fixed in Element 12.3.1**
- Similar fan sensor errors were observed on multiple clusters, indicating a systemic software/firmware-related issue rather than an isolated hardware failure

## Resolution

### Immediate Recovery
1. **Reboot the affected host**
2. Node will successfully **rejoin the cluster**
3. Verify cluster returns to a healthy state

### Permanent Fix
- Upgrade to **Element OS 12.3.1** or later, which resolves:
  - BMC communication issues
  - Fan / sensor false alerts

### Follow-up
- Upload logs to NetApp for analysis if the issue recurs before upgrading

## References
- Element OS 12.3 / 12.3.1 Release Notes (referenced by NetApp Support)

## Case Reference
- NetApp Case: 2008860464
