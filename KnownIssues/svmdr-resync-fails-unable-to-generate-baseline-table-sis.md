# SVM-DR Update/Resync Fails with "Unable to generate baseline for table sis" — Known Issue

## Symptoms
- SVM-DR relationship reports `healthy: false` but state stays `Snapmirrored` and status `Idle` — it is **not** `Broken-off`, so it looks superficially alive
- Lag time grows without bound (observed: 527 h → 552 h over one day) while the scheduled update keeps firing and failing identically
- **Every volume constituent reports `healthy: true`** — the failure is in the configuration (CRS) stream, not in any data transfer
- `snapmirror update` never recovers it, no matter how many times the schedule retries
- One or more destination volumes carry a **numeric suffix appended to the volume name** that does not exist on the source, e.g. `<volname><msid>` where `<msid>` is a 10-digit volume MSID

### Actual Error

```
Last Transfer Error: Failed to generate baseline. Reason: CRS stream operation failed.
  Reason: CRS stream operation failed. Reason: Unable to generate baseline for table sis.
  The system might be busy, retry the operation after some time.
  Execute "snapmirror show -destination-vserver <DR-SVM> -fields last-transfer-error,unhealthy-reason -expand"
  to check if the constituent volumes have encountered errors.
```

### What the CRS diagnostics show (and why they mislead)

```
# On the DESTINATION cluster
set -priv advanced
snapmirror config-replication status show
    Vserver Streams: warning          <-- the only hint

# On the SOURCE cluster
snapmirror config-replication status show
    Vserver Streams: ok

# Both clusters
snapmirror config-replication status show-communication          # Remote Heartbeat: ok
snapmirror config-replication status show-aggregate-eligibility  # MDV_CRS_*_A / _B online, 0% used
```

CRS storage, aggregate eligibility and the inter-cluster heartbeat are all **healthy**. Do not spend time on them — the fault is a data-model mismatch, not a transport or capacity problem.

## Environment
- NetApp ONTAP 9.x with SVM-DR (`identity-preserve true`, `Volume MSIDs Preserved: true`)
- Verified on ONTAP 9.16.1P5 (source AFF, destination FAS)
- Any SVM-DR pair; independent of protocol or workload

## Root Cause
One or more volumes exist on the destination SVM that **no longer correspond to a volume on the source SVM**. They are typically left behind by an earlier interrupted volume rename, re-protect, or failed replication of a volume creation, and they show up with the volume's MSID appended to the name.

CRS builds a configuration baseline table-by-table. When it reaches the `sis` (storage-efficiency) table it walks the volume list, hits the orphaned entry that maps to nothing on the source, and loops:

```
[kern_crs:info] ERR: crs_internal: Baseline fetch failed for table sis -
  Loop detected in next() for table sis. Next on "<vserver> <volume path>" returned "<vserver> <volume path>".
[kern_crs:info] ERR: crs_streams: Unable to generate a local baseline for <uuid>
```

The baseline never completes, so every update fails at the config stage while the data constituents remain individually healthy.

### What creates the orphans in the first place

Both NetApp KBs list the cause as "still under investigation". One reproducible trigger has now been
observed directly: **creating a FlexClone on a source SVM that is itself protected by SVM-DR.**

A FlexClone is a new volume on the protected SVM. SVM-DR has to replicate that creation. When the
replication of the *creation* does not complete cleanly, the destination is left holding volumes that
map to nothing, which is exactly the state the `sis` baseline loop needs.

The fingerprint is a tight timestamp correlation. Compare three things:

```
volume clone show -vserver <protected-svm> \
    -fields volume,parent-vserver,parent-volume,parent-snapshot,split-estimate

volume snapshot show -vserver <protected-svm> -volume <parent-volume> \
    -fields snapshot,create-time,owners        # the clone's parent snapshot is tagged owners: "volume clone"

snapmirror show -destination-path <DR-SVM>: -fields unhealthy-reason,last-transfer-error
```

In the observed case the clone's parent snapshot was created at **12:17:53** and the SVM-DR
relationship went unhealthy at **12:15** the same day. Three clones were created; three orphans
appeared on the destination, carrying **the same names**, two of them with the volume MSID appended.

Two practical consequences:

- **Prefer cloning from the replica, not from the protected source.** If a SnapMirror or SVM-DR copy
  of the parent already exists on another SVM, clone there. It keeps new volumes off the protected
  SVM entirely.
- **If you must clone on a protected SVM, check the relationship afterwards.** A single
  `snapmirror show -fields state,status,healthy,lag-time` immediately after the clone completes
  turns a silent 3-week outage into a same-day fix. Nothing alerts on this by default.

## Diagnosis — you do NOT need the CRS mlog

Both NetApp KBs direct you to `/etc/log/mlog/crs.log` or `CRS-MLOG-TXT.GZ` from an AutoSupport bundle to identify the offending volume. In practice:

- The **live `crs.log` retains only ~14 hours** and frequently does not contain the `Loop detected` line at all
- **`snapmirror resync` names the offending volumes directly in its error**, which is faster and needs no support bundle:

```
Error: command failed: The following volumes "<vol_a>,<vol_b>1234567890,<vol_c>1234567891"
       on the destination Vserver are new volumes and do not correspond with the volumes
       on the source Vserver. Delete them using the (privilege: advanced)
       "volume delete -force" command. When this command completes, try the operation again.
```

Use that list. Cross-check it against the source before deleting anything:

```
volume show -vserver <source-svm> -volume <name>*     # on the SOURCE cluster
```

## Fix — verified procedure

Run everything on the **destination** cluster unless stated otherwise. `advanced` privilege required.

### 1. Stop the schedule from racing you

```
snapmirror modify -destination-path <DR-SVM>: -schedule ""
```

`snapmirror abort` alone is **not** enough. It kills the running transfer, but the schedule launches the next one within seconds and every subsequent command fails with `operation status is "Aborting"` and then `"Transferring"`.

### 2. Quiesce and confirm it settled

```
snapmirror quiesce -destination-path <DR-SVM>:
snapmirror show -destination-path <DR-SVM>: -fields state,status,healthy
```

Wait for `status: Quiesced`. Only then continue.

### 3. Break

```
snapmirror break -source-path <SOURCE-SVM>: -destination-path <DR-SVM>:
```

Expect `Broken-off / Idle`. ONTAP prints a notice about queued quota and efficiency callback jobs — those complete on their own and drop out of `job show`; look in `job history show -vserver <DR-SVM>` if you want to confirm.

### 4. Resync, read the error, delete the orphans

```
snapmirror resync -source-path <SOURCE-SVM>: -destination-path <DR-SVM>:
```

It fails and names the volumes. Delete each one, then purge the recovery queue — the resync will not proceed while they sit in it:

```
volume delete -vserver <DR-SVM> -volume <orphan-volume>
volume recovery-queue purge-all -vserver <DR-SVM>
```

### 5. Resync again

```
snapmirror resync -source-path <SOURCE-SVM>: -destination-path <DR-SVM>:
```

Answer `y` to:

```
Warning: All data newer than snapshot "vserverdr.0.<uuid>.<timestamp>" on Vserver "<DR-SVM>" will be deleted.
```

This is safe in the normal case: the destination SVM is `stopped`, nothing writes to it, so there is no newer data of consequence.

### 6. Restore the schedule — do not skip this

```
snapmirror modify -destination-path <DR-SVM>: -schedule <schedule-name>
snapmirror show -destination-path <DR-SVM>: -fields schedule,state,status,healthy,lag-time
```

If you forget, the resync succeeds and DR then silently never updates again.

### Monitoring the resync

The top-level relationship shows no progress figure. Watch the constituents:

```
snapmirror show -destination-vserver <DR-SVM> -expand -fields destination-path,state,status,total-progress
```

Correct mapping is itself a success signal: the destination names come back **without** the numeric suffixes.

**Progress is not monotonic, and a flat count is not a stall.** Measured over a two-hour resync,
polling every 10 minutes:

```
13:47  Snapmirrored=37  Transferring=17  Idle=17  Broken-off=1
13:57  Snapmirrored=37  Transferring=6   Idle=29  Broken-off=1
14:17  Snapmirrored=37  Transferring=4   Idle=33  Broken-off=1
14:27  Snapmirrored=37  Transferring=3   Idle=34  Broken-off=1
   ...  Transferring oscillates 2-3 for over an hour while the large volumes finish ...
15:47  Snapmirrored=38  Transferring=0   Idle=38  Broken-off=0   <- flips in one step
```

The top-level relationship stays `Broken-off` / `Transferring` for the whole run and flips to
`Snapmirrored` / `Idle` only when the last constituent lands. Do not intervene because the count
stopped falling.

Sizing, from the same run: **2.56 TB in 2 h 02 m 37 s**, about 356 MB/s sustained. That matched the
sum of `size`/`used` on the deleted volumes' sources beforehand, so
`volume show -vserver <source-svm> -volume <name> -fields size,used` is a reliable pre-flight
estimate of the transfer you are about to incur.

Lag time at completion reflects age-since-common-snapshot and will still look large while the last
constituents are transferring. It clears on the next scheduled update, not at the moment the resync
finishes.

## Safety facts worth knowing before you start

- **`snapmirror break` does not activate the destination SVM.** It only makes the destination volumes writeable. The SVM stays `Admin State: stopped` / `Operational State: stopped` and its LIFs stay `oper down`. Activation requires an explicit `vserver start`, which is part of the *failover* procedure and is not needed here.
- This matters for `identity-preserve` pairs, where the DR SVM holds **the same LIF addresses as production**. Those addresses only come up at `vserver start`, so break/resync carries no duplicate-IP risk. Do not run `vserver stop <source>` / `vserver start <destination>` — those are steps 4–6 of the failover task and would create an address conflict.
- The source SVM keeps serving clients throughout. Nothing in this procedure touches it.
- Deleting an orphaned **destination** volume destroys no source data. Any volume whose destination you delete is re-baselined in full by the resync — size those transfers before starting (observed: ~2.6 TB across three volumes).

## Resolution
Deleting the orphaned destination volumes and purging the recovery queue clears the CRS `sis` baseline loop. The resync then completes and the relationship returns to `Snapmirrored / Idle / healthy true`.

NetApp lists the underlying cause of the orphaning as "still under investigation" in both KBs. The remediation above is deterministic regardless.

## References
- NetApp KB: *During a resync of an SVMDR it fails with Unable to generate baseline for table sis* — `kb.netapp.com/on-prem/ontap/DP/SnapMirror/SnapMirror-KBs/a_resync_of_an_SVMDR_fails_with_unable_to_generate_baseline_for_table_sis`
- NetApp KB: *SVM DR update/initialize fails with error "Unable to generate baseline for table sis"* — `kb.netapp.com/on-prem/ontap/DP/SnapMirror/SnapMirror-KBs/SVM_DR_update_or_initialize_fails_with_error_Unable_to_generate_baseline_for_table_sis`
- ONTAP docs: *Make SVM destination volumes writeable* — `docs.netapp.com/us-en/ontap/data-protection/make-svm-destination-volumes-writeable-task.html` (steps 1–3 only for this repair; steps 4–6 are failover)
- Project skill: [SVM-DR](../.github/skills/svm-dr/SKILL.md)

## Notes
- The two KBs offer a "delete the impacted destination volume" option and a "break then resync" option. In practice you need **both**, in this order: break first so resync becomes valid, then let resync name the volumes, then delete and resync again.
- KB1's alternative (unprotect the source volume, delete the destination volume, resync, re-protect) avoids the break entirely and is worth considering when only one volume is implicated and you would rather not leave the relationship `Broken-off` at any point.
- If the resync fails again with the same `table sis` error after the orphans are gone, stop. Do not loop on resync — the relationship is then parked at `Broken-off`, which is a worse posture than a lagging `Snapmirrored`. Raise a case with an AutoSupport so support can read the rotated CRS mlog.
