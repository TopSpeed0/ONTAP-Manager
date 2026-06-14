# NetApp Case Summary – 2009038729 (HCI disk failed)

## 🧾 Case Overview
- **Case Number:** 2009038729  
- **Product:** NetApp SolidFire / NetApp HCI  
- **Incident:** `driveFailed` alert  
- **Affected Node:** NodeID 9  
- **Affected Slot:** Slot 0  
- **Timeframe:** January–March 2022  
- **Customer Contact:** [Bohadana, Yitzhak](https://www.office.com/search?q=Bohadana%2c+Yitzhak&EntityRepresentationId=88b1f3e0-f056-4c51-a615-8f52060c255d)  

[1](https://outlook.office365.com/owa/?ItemID=AAMkAGNhYjk3NjliLWRkNjYtNDdjNS05ZjJhLThlNDdmMDYxYjVjYQBGAAAAAAAGRCxapeEuTI8Rk25YN8wGBwBlIM2hzC3dSK2NkNgCby%2fuAAAAAAEJAABlIM2hzC3dSK2NkNgCby%2fuAABQBthVAAA%3d&exvsurl=1&viewmodel=ReadMessageItem)

---

## ❓ Problem Description
- A **disk failure alert** (`driveFailed`) was reported on **Node 9, Slot 0**
- Alert raised concerns about storage health and required intervention
- No immediate node panic, but corrective actions were required to stabilize the cluster

[1](https://outlook.office365.com/owa/?ItemID=AAMkAGNhYjk3NjliLWRkNjYtNDdjNS05ZjJhLThlNDdmMDYxYjVjYQBGAAAAAAAGRCxapeEuTI8Rk25YN8wGBwBlIM2hzC3dSK2NkNgCby%2fuAAAAAAEJAABlIM2hzC3dSK2NkNgCby%2fuAABQBthVAAA%3d&exvsurl=1&viewmodel=ReadMessageItem)

---

## 🔍 Root Cause
- A **failed SSD drive** in Slot 0 on Node 9 triggered the SolidFire `driveFailed` condition
- No indication of a systemic cluster-wide failure; issue localized to a single node/disk

[1](https://outlook.office365.com/owa/?ItemID=AAMkAGNhYjk3NjliLWRkNjYtNDdjNS05ZjJhLThlNDdmMDYxYjVjYQBGAAAAAAAGRCxapeEuTI8Rk25YN8wGBwBlIM2hzC3dSK2NkNgCby%2fuAAAAAAEJAABlIM2hzC3dSK2NkNgCby%2fuAABQBthVAAA%3d&exvsurl=1&viewmodel=ReadMessageItem)

---

## ✅ Resolution / Actions Taken

### 1. Immediate Mitigation
- **Move primaries away from the affected node** to reduce load and risk  
- **Restart the SolidFire master service** (instead of rebooting the node) to clear the alert safely  
- Node restart was **explicitly avoided**

[1](https://outlook.office365.com/owa/?ItemID=AAMkAGNhYjk3NjliLWRkNjYtNDdjNS05ZjJhLThlNDdmMDYxYjVjYQBGAAAAAAAGRCxapeEuTI8Rk25YN8wGBwBlIM2hzC3dSK2NkNgCby%2fuAAAAAAEJAABlIM2hzC3dSK2NkNgCby%2fuAABQBthVAAA%3d&exvsurl=1&viewmodel=ReadMessageItem)

### 2. Support-Led Operations
- Certain operations (master service restart and slice rebalance) were confirmed as **NetApp Support–only actions**
- Maintenance window scheduled and coordinated with NetApp Support engineers

[1](https://outlook.office365.com/owa/?ItemID=AAMkAGNhYjk3NjliLWRkNjYtNDdjNS05ZjJhLThlNDdmMDYxYjVjYQBGAAAAAAAGRCxapeEuTI8Rk25YN8wGBwBlIM2hzC3dSK2NkNgCby%2fuAAAAAAEJAABlIM2hzC3dSK2NkNgCby%2fuAABQBthVAAA%3d&exvsurl=1&viewmodel=ReadMessageItem)

### 3. Data Rebalancing
- **RebalanceSlices API** executed after stabilizing the node to restore data distribution across the cluster

[1](https://outlook.office365.com/owa/?ItemID=AAMkAGNhYjk3NjliLWRkNjYtNDdjNS05ZjJhLThlNDdmMDYxYjVjYQBGAAAAAAAGRCxapeEuTI8Rk25YN8wGBwBlIM2hzC3dSK2NkNgCby%2fuAAAAAAEJAABlIM2hzC3dSK2NkNgCby%2fuAABQBthVAAA%3d&exvsurl=1&viewmodel=ReadMessageItem)

---

## 🛠 Technical References / APIs
- **SolidFire API – MovePrimariesAwayFromNode**
- **SolidFire API – RebalanceSlices**

**API Documentation:**
- SolidFire API Reference  
  https://docs.netapp.com/sfe-122/index.jsp?topic=%2Fcom.netapp.doc.sfe-api%2FGUID-D10750FA-F83E-43C2-A44D-4125D3719CA4.html  
[1](https://outlook.office365.com/owa/?ItemID=AAMkAGNhYjk3NjliLWRkNjYtNDdjNS05ZjJhLThlNDdmMDYxYjVjYQBGAAAAAAAGRCxapeEuTI8Rk25YN8wGBwBlIM2hzC3dSK2NkNgCby%2fuAAAAAAEJAABlIM2hzC3dSK2NkNgCby%2fuAABQBthVAAA%3d&exvsurl=1&viewmodel=ReadMessageItem)

**Postman / API Testing KB:**
- How to install and configure Postman for Element APIs  
  https://kb.netapp.com/Advice_and_Troubleshooting/Data_Storage_Software/Element_SDK/How_to_install_and_configure_Postman_to_run_Element_software_APIs  
[1](https://outlook.office365.com/owa/?ItemID=AAMkAGNhYjk3NjliLWRkNjYtNDdjNS05ZjJhLThlNDdmMDYxYjVjYQBGAAAAAAAGRCxapeEuTI8Rk25YN8wGBwBlIM2hzC3dSK2NkNgCby%2fuAAAAAAEJAABlIM2hzC3dSK2NkNgCby%2fuAABQBthVAAA%3d&exvsurl=1&viewmodel=ReadMessageItem)

---

## 📌 Case Status
- Mitigation and corrective actions completed during coordinated maintenance
- Cluster stabilized without node reboot
- **Case closed after confirmation from NetApp Support**

[1](https://outlook.office365.com/owa/?ItemID=AAMkAGNhYjk3NjliLWRkNjYtNDdjNS05ZjJhLThlNDdmMDYxYjVjYQBGAAAAAAAGRCxapeEuTI8Rk25YN8wGBwBlIM2hzC3dSK2NkNgCby%2fuAAAAAAEJAABlIM2hzC3dSK2NkNgCby%2fuAABQBthVAAA%3d&exvsurl=1&viewmodel=ReadMessageItem)

---

## 🧠 Executive Summary (Short)
A single SSD failure on NetApp HCI Node 9 triggered a `driveFailed` alert. NetApp Support mitigated the issue by moving primaries, restarting the SolidFire master service, and rebalancing data—stabilizing the cluster without rebooting the node. The case was closed successfully.