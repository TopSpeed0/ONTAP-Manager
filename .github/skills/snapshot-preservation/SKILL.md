---
name: snapshot-preservation
description: 'Safely preserve an ONTAP snapshot across policy rotation, space-triggered autodelete, and accidental deletion. Use for production iSCSI/Proxmox datastores, snapshot rename, KEEP namespace, defer-delete prefix, SnapLock snapshot locking, preservation pre-flight, or evaluating an ONTAP snapshot preservation script.'
argument-hint: 'Provide cluster, SVM, volume, snapshot name, desired retention/expiry, and whether the target is an iSCSI/Proxmox production datastore.'
---

# ONTAP Snapshot Preservation

## Purpose

Preserving an ONTAP snapshot is not one operation. Three independent mechanisms can remove or invalidate it, and each requires a different control:

| Risk | ONTAP mechanism | Control | Strength |
|---|---|---|---|
| Snapshot-policy rotation | Policy schedule/prefix and copy count | Rename out of the effective policy prefix namespace | Protects against policy rotation only |
| Space-triggered deletion | Volume snapshot autodelete | `defer-delete=prefix` with a reviewed prefix | Deleted last, not never |
| Manual/admin/malicious deletion | Normal snapshot deletion | SnapLock snapshot locking with an expiry | True immutability until expiry, if prerequisites are met |

Do not describe rename as "setting expiry". Outside SnapLock, ONTAP does not provide a generic per-snapshot never-expire switch. Do not describe autodelete defer as immutable protection.

## Safety boundary

- Default to read-only discovery and a dry run.
- State-changing commands must be shown explicitly and reviewed before a human runs them.
- Never silently enable volume-wide snapshot locking, alter autodelete, rename a SnapMirror reference snapshot, or delete a snapshot.
- For production iSCSI/Proxmox datastores, treat a rename as a storage-control change even though it does not alter LUN data.
- Do not use `--allow-snapmirror-owned` merely to get past a pre-flight refusal. Confirm the relationship and common/exported snapshot fields first.
- Never put passwords, tokens, or decrypted secrets in command arguments, scripts, logs, or reports.
- Use the configured cluster alias and workspace credential mechanisms; never hardcode cluster names or management IPs in tracked skill content.

## Required pre-flight

Run the following read-only checks against the exact SVM, volume, and snapshot. Use the workspace's native `Get-Nc*` cmdlets where available; use `<cluster>-ssh` or `Get-<Alias>Csv` as the fallback.

```text
volume snapshot show -vserver <svm> -volume <volume> -snapshot <snapshot> -fields owners,snapmirror-label,expiry-time,snaplock-expiry-time,state,size,create-time
volume snapshot autodelete show -vserver <svm> -volume <volume>
volume show -vserver <svm> -volume <volume> -fields snapshot-policy,snapshot-locking-enabled,state,space-guarantee
snapshot policy show -vserver <svm> -policy <policy> -fields schedule,prefix,count,retention-period
```

If a field is rejected on the ONTAP release, first query the live field catalog (`-fields ?`) and record the supported equivalent. Never convert an unsupported/unknown field into a false value.

For a snapshot owned by SnapMirror, also inspect the relationship before considering any rename:

```text
snapmirror show -destination-path <svm>:<volume> -fields relationship-status,mirror-state,exported-snapshot,newest-snapshot
```

For a production datastore, check capacity before any defer or lock decision:

```text
volume show-space -vserver <svm> -volume <volume>
storage aggregate show -fields aggregate,size,available,percent-used
```

Record the evidence in the change notes: policy prefix/copy count, current snapshot owners and state, autodelete enabled/trigger/commitment/defer settings, locking state, and available capacity.

## Policy rotation: safe rename

The effective policy prefix is the prefix configured on the policy copy, normally matching the schedule name. The safe rule is:

> The final name must not match `^<effective-policy-prefix>\.`.

Do not rely on folklore about a numeric suffix, `.keep`, `.hold`, or whether the trailing text parses as a timestamp. A suffix may appear to survive one rotation but is not a durable production control unless the exact ONTAP behavior is verified and accepted.

Prefer a separate namespace, for example:

```text
KEEP_daily_1830.2026-08-10_1830
```

This has two useful properties:

- It cannot match a policy prefix such as `daily_18:30`.
- It avoids punctuation such as `:` in generated target names, which is important for helper scripts that validate snapshot names conservatively.

The ONTAP CLI rename syntax is:

```text
volume snapshot rename -vserver <svm> -volume <volume> -snapshot <old-name> -new-name <new-name>
```

Verify that the source exists, the destination does not exist, the source is not a hard-block owner, and the destination escapes every effective policy prefix before presenting the rename.

### Owner gates

Refuse the rename when `owners` contains a reference that must not be renamed, including:

- `volume_move`
- clone/reference ownership
- NDMP reference ownership
- other ONTAP states that make the snapshot a backing/reference copy

Treat `snapmirror` and `sync_snapmirror` as a separate approval gate. Renaming a common/exported SnapMirror snapshot can invalidate the relationship or force a re-baseline. Only proceed after checking the relationship's exported/common snapshot fields and receiving explicit operator approval.

## Space-triggered autodelete

Snapshot rename does not remove a snapshot from volume autodelete eligibility. First inspect:

- `enabled`
- `trigger` (`volume` or `snap_reserve`)
- `commitment`
- `defer_delete`
- `defer_delete_prefix`

The optional control is:

```text
volume snapshot autodelete modify -vserver <svm> -volume <volume> -defer-delete prefix -defer-delete-prefix KEEP_
```

This is a **volume-wide** change. Apply it only when:

1. The current autodelete configuration was captured.
2. No different defer prefix is already protecting another snapshot set.
3. The impact on all snapshots in the volume was reviewed.
4. Capacity and the expected expiry window were reviewed.

`defer-delete=prefix` means snapshots matching the prefix are deleted **last**. It does not mean they can never be deleted.

If `commitment=destroy`, do not present defer as protection. The volume needs a separate capacity/remediation decision, and backing-function locks may still be removed by the destroy commitment. Do not silently overwrite an existing defer prefix; reconcile it manually.

## SnapLock snapshot locking

SnapLock snapshot locking is the only control in this workflow that provides true deletion immutability until its expiry. It requires all of the following:

- ONTAP 9.12.1 or later for the supported snapshot-locking workflow.
- SnapLock licensing/entitlement on the cluster.
- The target volume has `snapshot-locking-enabled=true`.
- A deliberately chosen expiry based on business recovery need and aggregate/volume capacity.

Do not enable locking implicitly from a preservation script. Enabling `snapshot-locking-enabled` is a volume-wide change and should be a separate reviewed change with a rollback/capacity plan. Existing snapshots and operational behavior must be understood first.

After the volume is explicitly approved and locking is enabled, the expiry operation is conceptually:

```text
volume snapshot modify-snaplock-expiry-time -vserver <svm> -volume <volume> -snapshot <final-name> -snaplock-expiry-time "<expiry>"
```

Verify the resulting `snaplock-expiry-time` and document that the snapshot cannot be deleted, including by an administrator, until that expiry. Never choose "as long as possible" without checking free capacity and expected change rate.

## Recommended execution sequence

1. **Discover** the exact SVM, volume, snapshot, policy prefix, owners, SnapMirror relationship, autodelete configuration, locking state, and capacity.
2. **Choose a final name** outside every policy prefix. Prefer `KEEP_<normalized-schedule>.<timestamp>`; do not assume `.keep` is sufficient.
3. **Dry-run** the preservation helper, if one is used. The dry run must show the proposed rename and every volume-wide side effect.
4. **Human review** of the source/destination names, owner gates, relationship state, autodelete impact, and expiry/capacity.
5. **Rename** the snapshot manually using `-new-name`.
6. **Optionally configure defer-delete** only after a separate review of the volume-wide autodelete impact.
7. **Optionally apply SnapLock expiry** only after the volume-level prerequisite and capacity approval are complete.
8. **Verify** the final name, state, owners, labels, creation time, autodelete configuration, and lock expiry.
9. **Observe the next policy run** as additional evidence, not as the primary protection mechanism. A scheduled observation cannot replace the pre-flight controls.

## Python helper integration

A preservation helper may combine discovery, rename, defer-delete, and optional locking, but it must retain these gates:

- Use an explicit `--new-name` when the source contains a colon or other punctuation that the helper's target-name validator rejects.
- Do not use a default such as `KEEP_` plus the complete source name if that produces an invalid target.
- Refuse hard-block owners and require an explicit, evidence-backed override for SnapMirror-owned snapshots.
- Refuse or clearly report `snapshot-locking-enabled=false` when `--lock-until` is requested; do not enable the volume setting implicitly.
- Treat `--defer-autodelete` as a volume-wide mutation and refuse to overwrite a different existing defer prefix.
- Retry only idempotent reads, PATCHes whose convergence is verified, and async job polling. Never retry a destructive deletion.
- Return distinct exit states for pre-flight refusal, authentication/TLS failure, API failure, and post-change verification failure.

For the current helper design, a safe explicit target looks like:

```text
--snapshot daily_18:30.2026-08-10_1830.keep --new-name KEEP_daily_1830.2026-08-10_1830
```

Do not add `--lock-until` until a live pre-flight proves the volume is configured for snapshot locking and the expiry has been approved.

## Verification checklist

After a change, verify all of the following against the exact volume:

```text
volume snapshot show -vserver <svm> -volume <volume> -snapshot <final-name> -fields snapshot,owners,snapmirror-label,expiry-time,snaplock-expiry-time,state,size,create-time
volume snapshot autodelete show -vserver <svm> -volume <volume>
```

Expected results:

- The final snapshot name is present exactly once.
- The creation time and size are unchanged by a rename.
- The final name does not match any policy prefix.
- Owners and SnapMirror label are unchanged and understood.
- If defer was approved, the volume reports the reviewed prefix.
- If locking was approved, the requested lock expiry is present.
- Any missing/unknown field is reported as unknown, never fabricated as `false`, zero, or empty.

## Production iSCSI/Proxmox checklist

Before preserving a snapshot on a volume backing a Proxmox datastore:

- Confirm the exact Proxmox storage-to-LUN-to-volume mapping.
- Confirm the LUN is not being used for a live restore, clone, migration, or backup job.
- Confirm the snapshot is not a SnapMirror/common reference or clone backing snapshot.
- Confirm available aggregate and volume space for the complete expiry window.
- Prefer rename-only first; treat autodelete defer and SnapLock as separate changes.
- Do not test protection by waiting for a production policy run when a pre-flight can prove the namespace and configuration.
- Never restore or expose a snapshot to Proxmox without a separate consistency and host-impact plan.

## Evidence and rollback notes

A rename does not alter snapshot contents, creation time, or LUN data. The operator must retain the before/after names and verification output. If a rename must be reversed, use another explicit `volume snapshot rename` after re-running the same owner, policy, and relationship gates; do not assume a reverse rename is safe merely because the first rename succeeded.

Never delete the source or destination as a cleanup step. Snapshot deletion is a separate, explicitly approved operation.
