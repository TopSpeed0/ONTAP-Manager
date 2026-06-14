# NetApp Case Summary – 2010148139 (`spares.low`)

## 🧾 Case Overview
- **Case Number:** 2010148139  
- **Customer:** Cognyte Software Ltd.  
- **Platform:** NetApp ONTAP C800 (NoSaveCore)  
- **Timeframe:** September–October 2024  
- **Topic:** `spares.low` alerts, Advanced Disk Partitioning (ADPv2), and core dump behavior

---

## ❓ Core Questions Addressed
1. Is **one partitioned spare disk per HA pair** sufficient?
2. Can a **core dump be generated during a panic** with this configuration?
3. Does `spares.low` affect **core dump creation**?
4. Are additional **firewall rules** required?

---

## ✅ Final Conclusions (NetApp-Confirmed)

### 1. Core Dump Behavior (NoSaveCore Platforms)
- The **C800 is a NoSaveCore platform**
- **Core dumps are written to the node boot device**, not to spare disks
- `spares.low` **does NOT block or prevent core dump creation**
- No firewall rules are required **for dumping itself**
- Firewall access is only needed if **AutoSupport uploads** core files externally  
[1](https://outlook.office365.com/owa/?ItemID=AAMkAGNhYjk3NjliLWRkNjYtNDdjNS05ZjJhLThlNDdmMDYxYjVjYQBGAAAAAAAGRCxapeEuTI8Rk25YN8wGBwClyUzxQdXEQ6EoEmtUUKHpAAD13iNEAAClyUzxQdXEQ6EoEmtUUKHpAAD13l7KAAA%3d&exvsurl=1&viewmodel=ReadMessageItem)

**Relevant KB:**
- *What is a SaveCore platform*  
  https://kb.netapp.com/on-prem/ontap/OHW/OHW-KBs/What_is_a_savecore_platform

---

### 2. Spare Disk Requirement (ADPv2 – root-data-data)
- NetApp general **best practice**:
  - At least **1 spare per disk type per node** (for resiliency)
- **Functionally valid for this case**:
  - **1 whole spare disk per HA pair**, partitioned across nodes, **is acceptable**
- This configuration **supports panic scenarios and core dump generation**  
[2](https://outlook.office365.com/owa/?ItemID=AAMkAGNhYjk3NjliLWRkNjYtNDdjNS05ZjJhLThlNDdmMDYxYjVjYQBGAAAAAAAGRCxapeEuTI8Rk25YN8wGBwClyUzxQdXEQ6EoEmtUUKHpAAD13iNEAAClyUzxQdXEQ6EoEmtUUKHpAAD13l7NAAA%3d&exvsurl=1&viewmodel=ReadMessageItem)

**Relevant KBs:**
- *Spare requirements – spares.low resolution guide*  
  https://kb.netapp.com/on-prem/ontap/OHW/OHW-KBs/Spares_Low_Resolution_guide
- *Rules for Advanced Disk Partitioning*  
  https://kb.netapp.com/on-prem/ontap/Ontap_OS/OS-KBs/What_are_the_rules_for_Advanced_Disk_Partitioning

---

### 3. Cause of `spares.low` Alerts
- Alerts were influenced by **known ONTAP bugs**, including:
  - Missing or delayed auto-partitioning
  - False `spares.low` conditions during ADP operations
- Affected ONTAP versions prior to fixes
- **Resolved in ONTAP 9.14.1P7**  
[2](https://outlook.office365.com/owa/?ItemID=AAMkAGNhYjk3NjliLWRkNjYtNDdjNS05ZjJhLThlNDdmMDYxYjVjYQBGAAAAAAAGRCxapeEuTI8Rk25YN8wGBwClyUzxQdXEQ6EoEmtUUKHpAAD13iNEAAClyUzxQdXEQ6EoEmtUUKHpAAD13l7NAAA%3d&exvsurl=1&viewmodel=ReadMessageItem)

**Referenced Bugs / KBs:**
- BURT 1209463 – No spare detected  
- BURT 1591125 – Spare Low alert  
- BURT 1361016 – Auto-partition failure  
- BURT 1474637 – Spares low during ADP  
- BURT 1439003 – ADP-related spare alerts  
- *Correct misaligned spare partitions*  
  https://docs.netapp.com/us-en/ontap/disks-aggregates/correct-misaligned-spare-partitions-task.html
- *Spare disks get auto-partitioned when not needed*  
  https://kb.netapp.com/on-prem/ontap/OHW/OHW-KBs/Spare_disks_get_auto-partitioned_when_not_needed

---

## 📌 Case Closure
- All technical questions were clarified
- Summary reviewed and confirmed in meetings
- **Case closed and archived** by NetApp  
[3](https://outlook.office365.com/owa/?ItemID=AAMkAGNhYjk3NjliLWRkNjYtNDdjNS05ZjJhLThlNDdmMDYxYjVjYQBGAAAAAAAGRCxapeEuTI8Rk25YN8wGBwClyUzxQdXEQ6EoEmtUUKHpAAD13iNEAAClyUzxQdXEQ6EoEmtUUKHpAAD13l7MAAA%3d&exvsurl=1&viewmodel=ReadMessageItem)

---

## 🧠 Executive Summary (Short)
On ONTAP C800 (NoSaveCore), core dumps are written to the boot device; **one partitioned spare disk per HA pair is sufficient**, and `spares.low` alerts were caused by known ADP-related ONTAP bugs—now fixed. The case