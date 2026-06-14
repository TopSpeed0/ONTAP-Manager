# Trident – Vserver-DR Blocks Dynamic PVC Deletion (JFrog Orphaned Volumes)

**Status:** Confirmed issue (no NetApp case #)
**Cluster:** <cluster-name> (<s3-svm>)
**Date logged:** 2026-06-10

---

## Issue (CONFIRMED FACT)

NetApp Trident does **not** pass `vserver-dr-protected=unprotect` to ONTAP during dynamic PVC provisioning. As a result:

1. Any PVC dynamically created by JFrog (or any K8s workload) inherits the Vserver-level SnapMirror DR protection by default.
2. When JFrog deletes a PVC (via `helm uninstall`, `kubectl delete pvc`, or pipeline cleanup), Kubernetes signals Trident to delete the backend volume.
3. Trident **successfully deletes** the volume on the **source** cluster (<cluster-name> / `<svm-name>_med1`).
4. SVM-DR replication tries to sync the deletion to the **DR** cluster (`<dr-cluster>` / `<svm-name>`) using `synthetic_remove_method`.
5. ONTAP on the DR side **refuses** to delete the volume if it has clones, causing the SnapMirror transfer to **fail**.
6. Result: **orphaned/phantom volume on DR only** (source is clean), and a "Mirror Replication Update Failed" alert fires in Active IQ.

JFrog does not communicate with NetApp directly — deletions happen strictly at the Kubernetes layer.

### Active IQ Alert (actual error)

```
Risk          - Mirror Replication Update Failed
Impact Area   - Protection
Severity      - Error
State         - New
Source        - <svm-name>_med1:-><svm-name>:
Cluster Name  - <dr-cluster>
Cluster FQDN  - <cluster-fqdn>
Trigger Condition - Reason: 'Transfer failed'. Last transfer error was
  'Failed to apply the source Vserver configuration.
   Reason: Apply failed for Object: volume Method: synthetic_remove_method.
   Reason: Failed to delete volume "trident_pvc_..." because it has one or
   more clones.'
```

### Error behavior

- The error is **transient** — on the **next** scheduled replication (every 3 hours) the sync succeeds and the SVM-DR relationship returns to healthy.
- Each occurrence is a **different PVC** — it's never the same volume failing twice. JFrog pipelines delete different PVCs over time, each triggering a one-time alert then self-healing.
- However, each **orphaned volume persists on DR** even after the relationship heals. The phantom volumes **accumulate** over time and are never cleaned up automatically.

---

## Gemini Suggested Fix — REJECTED

> **Google Gemini suggested a K8s CronJob that detects "Released" PVs and deletes them via ONTAP API. This is WRONG.**

**Why it doesn't work:**
- Trident already **successfully deletes** the volume on the source — there are no stuck "Released" PVs in Kubernetes to find.
- The orphaned volumes exist only on the **DR cluster** (`<dr-cluster>` / `<svm-name>`), which Kubernetes has no visibility into.
- Gemini completely missed that the problem is on the DR side, not the source/K8s side.

---

## Actual Fix Options (TO BE EVALUATED)

### Option A: Preventive — unprotect Trident volumes at provisioning time (SOURCE side)

Set `vserver-dr-protection=unprotected` on Trident volumes **right after** Trident creates them on `<cluster-name>`. This prevents them from being replicated to DR at all — acceptable if JFrog volumes are transient and don't need DR.

Reference script: `<user-docs>\Kubernetes Administration and Using NetApp Trident\STRSW-ILT-UATWK\Exercise 6\exercise6Task5-unprotect-vols.sh`

```bash
# On source cluster (<cluster-name>), unprotect all trident PVC volumes:
vol modify -vserver <svm-name>_med1 -volume trident_pvc_* -vserver-dr-protection unprotected
```

**Challenge:** Need to detect when Trident provisions a new volume and run this immediately. Could be a cron that periodically sweeps for new `trident_pvc_*` volumes still set to `protected`.

### Option B: Reactive — clean up orphans on DR using `vserver config override` (DR side)

When SVM-DR can't replicate a volume deletion, use `vserver config override` on the DR cluster (`<dr-cluster>`) to manually delete the orphaned volume.

```bash
# On DR cluster (<dr-cluster>), diag mode:
<dr-cluster>::*> vserver config override -command "vol offline -vserver <svm-name> -volume trident_pvc_xxxxx"
<dr-cluster>::*> vserver config override -command "vol delete -vserver <svm-name> -volume trident_pvc_xxxxx"
```

**Implementation approach:**
1. Detect when JFrog triggers a PVC deletion — need to figure out **what in the JFrog pipeline** sends the delete command to K8s/Trident.
2. Once we know the volume name being deleted, run `vserver config override` on `<dr-cluster>` via SSH to clean up the DR copy.
3. Trident has its own credential store — the OpenShift admin could potentially trigger this from a K8s Job that runs on PVC delete events.
4. **CLI passthrough via REST API may work** (see note below) — otherwise SSH is the fallback.

**REST API CLI Passthrough (UNVERIFIED — needs testing on `<dr-cluster>`):**

Google AI suggests ONTAP's `/api/private/cli` endpoint can execute `vserver config override`:

```bash
# Test this against <dr-cluster> — may or may not work
curl -X POST -u "admin:<password>" -k \
  "https://<cluster-fqdn>/api/private/cli/vserver/config/override" \
  -H "Content-Type: application/json" \
  -d '{"command": "vol offline -vserver <svm-name> -volume trident_pvc_xxxxx"}'

curl -X POST -u "admin:<password>" -k \
  "https://<cluster-fqdn>/api/private/cli/vserver/config/override" \
  -H "Content-Type: application/json" \
  -d '{"command": "vol delete -vserver <svm-name> -volume trident_pvc_xxxxx"}'
```

**Caveats:**
- `/api/private/cli` is a real ONTAP feature, but the exact path for `vserver config override` is unconfirmed.
- Requires diag-level privileges on the API service account (`security login rest-role modify`).
- If SVM-DR is `identity-preserve true`, some override commands may still fail with operation-not-permitted.
- **Must test on `<dr-cluster>` before relying on it.**

**Open questions:**
- What JFrog pipeline step triggers the PVC deletion? (`helm uninstall`? `kubectl delete pvc`? cleanup script?)
- Can the OpenShift admin add a finalizer/webhook that calls an SSH script before the PVC is fully deleted?
- Can we use Trident's stored credentials to SSH to `<dr-cluster>`, or do we need a separate service account?

### Option C: Combination — Option A + periodic DR cleanup

Best of both worlds:
1. Run Option A as a cron on source → stops **new** orphans from being created.
2. Run Option B once to clean up **existing** orphans on DR.

### Option D: NetApp feature request / support case

Ask NetApp to add `vserver-dr-protection` as a Trident backend config parameter. Proper long-term fix.

---

## API Test Script

Test script at workspace root: `Test-VserverConfigOverrideAPI.ps1`

Runs 3 checks against `<dr-cluster>`:

| Test | Endpoint | Purpose |
|------|----------|---------|
| 1 | `POST /api/private/cli/vserver/config/override` | Main test — uses a fake volume name, completely safe |
| 2 | `GET /api/private/cli/version` | Baseline — does `/api/private/cli` work at all? |
| 3 | `GET /api/cluster` | Sanity — is REST API reachable? |

```powershell
# Run from workspace root:
.\Test-VserverConfigOverrideAPI.ps1

# Or with explicit parameters:
.\Test-VserverConfigOverrideAPI.ps1 -Cluster <cluster-fqdn> -Credential (Get-Credential)
```

**Expected results:**
- Test 1 returns ONTAP error "volume not found" → **endpoint works**, REST automation is possible.
- Test 1 returns HTTP 404 → **endpoint doesn't exist**, SSH is the only option.
- Test 1 returns HTTP 401/403 → endpoint may exist but admin account lacks diag-level REST privileges.

**Test status:** NOT YET RUN
