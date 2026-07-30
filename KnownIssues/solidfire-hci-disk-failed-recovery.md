# SolidFire HCI Disk Failure Recovery Procedure — Known Issue

## Symptoms
- SolidFire `driveFailed` alert on a specific node and slot (e.g., Node 9, Slot 0)
- Storage health concern requiring intervention
- No immediate node panic, but corrective actions needed to stabilize the cluster

## Environment
- NetApp SolidFire / NetApp HCI
- Single SSD failure (localized to one node/disk, not a systemic cluster-wide failure)

## Root Cause
- A **failed SSD drive** in the affected slot triggered the SolidFire `driveFailed` condition

## Resolution

### Step 1: Move Primaries Away
- Use the **MovePrimariesAwayFromNode** API to reduce load and risk on the affected node

### Step 2: Restart Master Service
- **Restart the SolidFire master service** (instead of rebooting the node) to clear the alert safely
- Node restart should be **explicitly avoided** if possible

### Step 3: Rebalance Data
- Execute the **RebalanceSlices** API after stabilizing the node to restore data distribution across the cluster

### Important Notes
- Master service restart and slice rebalance are **NetApp Support-only actions** — coordinate with NetApp Support engineers
- Schedule a maintenance window before performing these operations

## References
- SolidFire API Reference — MovePrimariesAwayFromNode, RebalanceSlices:
  https://docs.netapp.com/sfe-122/index.jsp?topic=%2Fcom.netapp.doc.sfe-api%2FGUID-D10750FA-F83E-43C2-A44D-4125D3719CA4.html
- How to install and configure Postman for Element APIs:
  https://kb.netapp.com/Advice_and_Troubleshooting/Data_Storage_Software/Element_SDK/How_to_install_and_configure_Postman_to_run_Element_software_APIs

## Case Reference
- NetApp Case: 2009038729
