# AIQUM Cluster Discovery Failed After Upgrade (mTLS / Cloud Agent) — Known Issue

## Symptoms
- Active IQ Unified Manager reports: **"Cluster discovery failed. Rediscover the cluster after resolving the issue."**
- Issue appears **after upgrading to AIQUM 9.14**
- Discovery fails consistently; manual rediscovery attempts do not resolve it

## Environment
- Active IQ Unified Manager (AIQUM) 9.14
- ONTAP cluster with Cloud Agent enabled
- mTLS enabled

## Root Cause
- **Cloud Agent was enabled** alongside mTLS
- AIQUM experienced **mTLS communication issues** preventing proper communication with the ONTAP cluster
- Root cause matched **known NetApp bug: CAIQUM-6090**

## Resolution
1. **Disable Cloud Agent** in AIQUM settings
2. **Disable mTLS**
3. Re-attempt cluster discovery — it should succeed immediately
4. No further discovery failures should occur after these changes

## References
- NetApp Bug ID: **CAIQUM-6090** — AIQUM cluster discovery issues when Cloud Agent and mTLS are enabled together

## Case Reference
- NetApp Case: 2010112466
