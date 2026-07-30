# H610S PS2 Fan RPM False Positive Alert — Known Issue

## Symptoms
- Alert: **"PS2 Fan RPM is failed or missing"**
- Alerts occur only on **H610S storage nodes** (not H410S)
- Alerts resolve automatically within approximately **2 minutes**
- No actual hardware failure or performance impact

## Environment
- NetApp HCI with H610S storage nodes
- Affected firmware revisions (pre-fix)

## Root Cause
- **Known false positive** caused by the current firmware (FW) revision on H610S nodes
- The fan sensor reporting logic incorrectly triggers the alert

## Resolution
- Alerts that resolve within a few minutes can be **safely ignored**
- No corrective action required beyond monitoring
- NetApp DevOps has been working on a firmware fix to eliminate the false alerts

## References
- NetApp KB: https://kb.netapp.com/Advice_and_Troubleshooting/Hybrid_Cloud_Infrastructure/H_Series/H610S_fanSensor_alert_PSx_Fan_RPM_is_failed_or_missing

## Case Reference
- NetApp Case: 2008906763
