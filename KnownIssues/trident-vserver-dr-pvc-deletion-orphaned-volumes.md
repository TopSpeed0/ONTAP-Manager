# Trident Vserver-DR Blocks Dynamic PVC Deletion (Orphaned Volumes on DR) — Known Issue

## Symptoms
- Active IQ alert: **"Mirror Replication Update Failed"** on SVM-DR relationship
- Error message references `synthetic_remove_method` and "Failed to delete volume because it has one or more clones"
- Orphaned `trident_pvc_*` volumes accumulate on the DR cluster over time
- Source cluster is clean — volumes are successfully deleted there
- The error is **transient** — the next scheduled replication (e.g., every 3 hours) succeeds and the SVM-DR relationship returns to healthy
- Each occurrence involves a **different PVC** — it is never the same volume failing twice

### Actual Error (Active IQ)

```
Risk          - Mirror Replication Update Failed
Impact Area   - Protection
Severity      - Error
State         - New
Source        - <svm-name>:-><svm-name>:
Trigger Condition - Reason: 'Transfer failed'. Last transfer error was
  'Failed to apply the source Vserver configuration.
   Reason: Apply failed for Object: volume Method: synthetic_remove_method.
   Reason: Failed to delete volume "trident_pvc_..." because it has one or
   more clones.'
```

## Environment
- NetApp ONTAP with SVM-DR (identity-preserve) configured
- Astra Trident provisioner for Kubernetes/OpenShift
- Dynamically provisioned PVCs (e.g., from JFrog pipelines or any K8s workload)

## Root Cause
NetApp Trident does **not** pass `vserver-dr-protection=unprotected` to ONTAP during dynamic PVC provisioning. This causes the following chain:

1. Any dynamically created PVC inherits the Vserver-level SnapMirror DR protection by default
2. When the PVC is deleted (via `helm uninstall`, `kubectl delete pvc`, or pipeline cleanup), Trident **successfully deletes** the volume on the **source** cluster
3. SVM-DR replication attempts to sync the deletion to the **DR** cluster using `synthetic_remove_method`
4. ONTAP on the DR side **refuses** to delete the volume if it has clones
5. Result: orphaned/phantom volume on DR only, and a "Mirror Replication Update Failed" alert fires

The error self-heals on the next replication cycle, but the **orphaned volumes persist on DR** and accumulate over time.

## Fix Options (To Be Evaluated)

### Option A: Preventive — Unprotect Trident volumes at provisioning time (source side)

Set `vserver-dr-protection=unprotected` on Trident volumes right after creation. This prevents them from being replicated to DR — acceptable if the volumes are transient and don't need DR.

```bash
# On source cluster, unprotect all trident PVC volumes:
vol modify -vserver <svm-name> -volume trident_pvc_* -vserver-dr-protection unprotected
```

Can be implemented as a cron that periodically sweeps for new `trident_pvc_*` volumes still set to `protected`.

### Option B: Reactive — Clean up orphans on DR using vserver config override (DR side)

When SVM-DR can't replicate a volume deletion, use `vserver config override` on the DR cluster to manually delete the orphaned volume.

```bash
# On DR cluster, diag mode:
set -privilege diag
vserver config override -command "vol offline -vserver <svm-name> -volume trident_pvc_xxxxx"
vserver config override -command "vol delete -vserver <svm-name> -volume trident_pvc_xxxxx"
```

### Option C: Combination — Option A + periodic DR cleanup

1. Run Option A as a cron on source — stops **new** orphans from being created
2. Run Option B once to clean up **existing** orphans on DR

### Option D: NetApp feature request

Ask NetApp to add `vserver-dr-protection` as a Trident backend configuration parameter for a proper long-term fix.

### REST API CLI Passthrough (Unverified)

ONTAP's `/api/private/cli` endpoint may be able to execute `vserver config override`:

```bash
curl -X POST -u "admin:<password>" -k \
  "https://<cluster-fqdn>/api/private/cli/vserver/config/override" \
  -H "Content-Type: application/json" \
  -d '{"command": "vol offline -vserver <svm-name> -volume trident_pvc_xxxxx"}'
```

**Caveats:**
- `/api/private/cli` is a real ONTAP feature, but the exact path for `vserver config override` is unconfirmed
- Requires diag-level privileges on the API service account
- If SVM-DR is `identity-preserve true`, some override commands may still fail
- Must be tested before relying on it in automation

## Resolution
- No single definitive fix yet — evaluate Options A through D based on environment requirements
- Option C (combination) provides the most complete coverage

## References
- ONTAP documentation on `vserver-dr-protection` volume attribute
- Trident backend configuration documentation

## Notes
- A common AI-suggested fix (K8s CronJob to detect "Released" PVs and delete them via ONTAP API) is **incorrect** — Trident already successfully deletes the volume on the source. The problem is exclusively on the DR side, which Kubernetes has no visibility into.
