# Spares Low Alerts with ADPv2 and Core Dump Behavior on C800 — Known Issue

## Symptoms
- `spares.low` alerts on ONTAP C800 platform
- Concerns about whether spare disk count affects core dump generation during a panic
- False `spares.low` conditions during ADP (Advanced Disk Partitioning) operations

## Environment
- NetApp ONTAP C800 (NoSaveCore platform)
- Advanced Disk Partitioning v2 (ADPv2) with root-data-data layout
- ONTAP versions prior to 9.14.1P7

## Root Cause

### Core Dump on NoSaveCore Platforms
- The C800 is a **NoSaveCore platform**
- Core dumps are written to the **node boot device**, not to spare disks
- `spares.low` does **NOT block or prevent core dump creation**
- No firewall rules are required for dumping itself (only needed if AutoSupport uploads core files externally)

### Spare Disk Requirements (ADPv2)
- NetApp best practice: at least **1 spare per disk type per node**
- **1 whole spare disk per HA pair**, partitioned across nodes, is functionally acceptable
- This configuration supports panic scenarios and core dump generation

### False `spares.low` Alerts
- Alerts were caused by **known ONTAP bugs** related to ADP:
  - Missing or delayed auto-partitioning
  - False `spares.low` conditions during ADP operations
- **Resolved in ONTAP 9.14.1P7**

### Referenced ONTAP Bugs
- BURT 1209463 — No spare detected
- BURT 1591125 — Spare Low alert
- BURT 1361016 — Auto-partition failure
- BURT 1474637 — Spares low during ADP
- BURT 1439003 — ADP-related spare alerts

## Resolution
1. Upgrade to **ONTAP 9.14.1P7** or later to eliminate false `spares.low` alerts
2. Ensure at least **1 spare disk per HA pair** for ADPv2 configurations
3. Understand that on NoSaveCore platforms (C800), core dumps are written to the boot device — `spares.low` has no impact on core dump capability

## References
- What is a SaveCore platform:
  https://kb.netapp.com/on-prem/ontap/OHW/OHW-KBs/What_is_a_savecore_platform
- Spares Low Resolution Guide:
  https://kb.netapp.com/on-prem/ontap/OHW/OHW-KBs/Spares_Low_Resolution_guide
- Rules for Advanced Disk Partitioning:
  https://kb.netapp.com/on-prem/ontap/Ontap_OS/OS-KBs/What_are_the_rules_for_Advanced_Disk_Partitioning
- Correct misaligned spare partitions:
  https://docs.netapp.com/us-en/ontap/disks-aggregates/correct-misaligned-spare-partitions-task.html
- Spare disks get auto-partitioned when not needed:
  https://kb.netapp.com/on-prem/ontap/OHW/OHW-KBs/Spare_disks_get_auto-partitioned_when_not_needed

## Case Reference
- NetApp Case: 2010148139
