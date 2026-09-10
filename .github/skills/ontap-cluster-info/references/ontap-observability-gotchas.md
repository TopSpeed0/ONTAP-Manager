# ONTAP Observability — Measured Retention and Field Gotchas

Field-measured behaviour, not documentation theory. Verified on **ONTAP 9.16.1P5** (AFF-A1K source, FAS destination) during a September 2026 performance investigation. Re-verify on other releases before relying on the numbers.

The companion file `cluster-ontap-reference.md` covers architecture and command syntax from the ONTAP 9 docs. This file covers what the platform will and will not actually tell you.

---

## 1. REST metric retention — the requested interval is not the sample spacing

Endpoints: `/api/cluster/metrics`, `/api/storage/volumes/{uuid}/metrics`, `/api/cluster/nodes/{uuid}/metrics`, `/api/storage/aggregates/{uuid}/metrics`

| `interval=` | Window actually returned | Observed spacing | Samples |
|---|---|---|---|
| `15s` | ~1 hour | 15 s | — |
| `1h` | **~1 hour** (not hourly samples over a long window) | 15 s | — |
| `1d` | ~24 hours | — | — |
| `1w` | **7 days** | **30 minutes** | 336 |
| `1m` | **30 days** | **2 hours** | 360 |

Consequences:

- Anything older than ~24 hours needs `1w` or `1m`. **Nothing reaches beyond 30 days.**
- `interval` selects the *retention tier*, not the granularity. Always record and report the **observed** first/last timestamp and spacing, never the requested interval.
- Timestamps come back as UTC (`...Z`). PowerShell's `[datetime]` cast converts to local on parse — do not add an offset again on top of that.

```powershell
# window probe before trusting any series
$m = Invoke-RestMethod -Uri "$base/storage/volumes/$uuid/metrics?interval=1w&fields=timestamp,latency,iops&order_by=timestamp%20asc&max_records=1000" -Headers $h -SkipCertificateCheck
"{0} samples, {1} -> {2}" -f $m.records.Count, [datetime]$m.records[0].timestamp, [datetime]$m.records[-1].timestamp
```

## 2. These endpoints are performance-only — there is no space history

`latency`, `iops`, `throughput`. **No capacity or space time-series exists on the array.** `volume show` gives current state only.

If you need "how full was this volume on date X", the only source is **AIQUM** (Active IQ Unified Manager). Its REST API answers on 443 and requires its own credential — the ONTAP cluster credentials do not work against it.

Also: **`/api/svm/svms/{uuid}/metrics` does not exist** — returns `"API not found", code 3`. Aggregate per-SVM figures from the member volumes, or use aggregate-level metrics.

## 3. EMS retention is hours, not days

`/api/support/ems/events` was measured retaining only **~11–14 hours**. For any incident older than half a day the EMS record is already gone.

```powershell
# oldest/newest retained, cheaply
$o = Invoke-RestMethod -Uri "$base/support/ems/events?fields=time&max_records=1&order_by=time%20asc"  -Headers $h -SkipCertificateCheck
$n = Invoke-RestMethod -Uri "$base/support/ems/events?fields=time&max_records=1&order_by=time%20desc" -Headers $h -SkipCertificateCheck
```

Export EMS within 12 hours of an event, or rely on AutoSupport / AIQUM. Do not promise EMS evidence for a multi-day-old incident before checking the window.

Useful event to know: `nblade.execsOverLimit` fires when a client exceeds the **128 in-flight request** ceiling to a given LIF — a real signature of client-side NFS concurrency saturation.

## 4. Reading node log files without diag or systemshell

Works at `advanced` privilege:

```
set -priv advanced
system node run -node <node> -command "rdfile /etc/log/mlog/crs.log"
```

Note the live mlog files rotate fast — `crs.log` was observed holding only ~14 hours. For anything older, the file is in an AutoSupport bundle (`CRS-MLOG-TXT.GZ`), not on the node.

## 5. A FlexClone refresh destroys the clone's metric history

`netapp_dataops_cli clone volume --refresh`, and any delete-and-recreate cycle, gives the clone a **new UUID**. Its `/storage/volumes/{uuid}/metrics` history dies with the old UUID.

For nightly-refreshed clones you therefore cannot retrieve yesterday's per-volume I/O. Capture it the same day, or fall back to **aggregate-level** metrics, which survive.

## 6. `volume move` on a FlexClone splits it — and ONTAP offers the target without warning

A FlexClone shares blocks only within its parent's aggregate. Moving it to another aggregate forces a **full split**.

`volume move target-aggr show` will happily list a different aggregate as eligible for a FlexClone with **no warning at all**. Check before moving anything:

```
volume clone show -vserver <svm> -fields volume,parent-volume,parent-snapshot,split-estimate
```

`split-estimate` is the block copy you would incur. Observed case: a 4.29 TB split-estimate offered as a routine move target.

## 7. Deprecated NFSv3 transfer-size parameters are cosmetic — do not chase them

At `advanced` privilege an SVM commonly shows:

```
vserver nfs show -vserver <svm> -fields tcp-max-xfer-size,v3-tcp-max-read-size,v3-tcp-max-write-size
  tcp-max-xfer-size     262144
  v3-tcp-max-read-size  65536
  v3-tcp-max-write-size 65536
```

**`tcp-max-xfer-size` governs. The `v3-tcp-max-*` pair is deprecated and not honoured.**

Verified empirically: a Linux client mounting such an SVM negotiates `rsize=262144,wsize=262144`. Do not read `65536` as a 64 KB ceiling, do not "fix" it, and do not let it block a client-side `rsize`/`wsize` increase. Confirm from the client instead:

```bash
grep <lif-ip> /proc/mounts     # authoritative: what was actually negotiated
```

## 8. QoS — `*-fixed` policies may be user-defined, and `Is Shared` changes everything

`extreme-fixed` / `performance-fixed` / `value-fixed` can exist as **user-defined** policy groups alongside the built-in adaptive `extreme` / `performance` / `value`. Do not assume a name implies adaptive behaviour.

```
qos policy-group show -policy-group <name>
    Policy Group Class: user-defined
    Maximum Throughput: 50000IOPS,1.53GB/s
    Is Shared: false            <-- decisive
```

- `Is Shared: false` — **each** workload in the group gets its own ceiling
- `Is Shared: true` — all workloads **share** one ceiling

Never infer throttling from the presence of a policy. Measure it:

```
qos statistics volume latency show -vserver <svm> -volume <vol> -iterations 2
```

The **`QoS Max`** column is the delay actually being applied. `0ms` means the ceiling is not being hit.

## 9. The latency breakdown localises a LIF/volume placement mismatch

`qos statistics volume latency show` splits total latency into `Network | Cluster | Data | Disk | QoS Max | QoS Min | NVRAM | Cloud | FlexCache | SM Sync | VA | AVSCAN`.

A non-zero **`Cluster`** component means **indirect data access** — the client's LIF is on a different node than the volume, so every operation crosses the cluster interconnect.

Measured example: `Cluster` = 81–86 µs out of a 358–439 µs total (~20 %) for a volume whose LIF was on the partner node, against `Cluster` = 0 for a volume co-located with its LIF. This is the cleanest way to quantify the cost of a placement mismatch before proposing a `volume move` or a LIF migration.

## 10. `snapmirror abort` does not stop the schedule

`abort` kills the running transfer only. The schedule launches the next one within seconds, and subsequent commands then fail with `operation status is "Aborting"` followed by `"Transferring"`.

To take the scheduler out of the picture:

```
snapmirror modify -destination-path <path> -schedule ""    # reversible, deterministic
snapmirror quiesce -destination-path <path>                # then wait for status: Quiesced
```

Restore the schedule afterwards — a repaired relationship with `-schedule ""` never updates again, silently. See [SVM-DR table sis known issue](../../../../KnownIssues/svmdr-resync-fails-unable-to-generate-baseline-table-sis.md).

## 11. `snapmirror break` does not activate an SVM-DR destination

`break` makes the destination volumes writeable. The destination SVM stays `Admin State: stopped` / `Operational State: stopped`, subtype `dp-destination`, and its LIFs stay `oper down` (even with `status-admin: up`).

Activation requires an explicit `vserver start`. This matters for `identity-preserve true` pairs where the DR SVM holds the **same LIF addresses as production** — those addresses come up only at `vserver start`, so break/resync carries no duplicate-address risk, while `vserver stop <source>` + `vserver start <destination>` (the failover steps) certainly does.

## 12. Cluster timezone vs API timezone

ONTAP CLI output is in the cluster's configured timezone (`cluster date show`), while the REST metrics API returns UTC. When correlating CLI timestamps, log files and API series in one table, convert once and state which zone the table is in.

## 13. `sis-space-saved` does not report Auto Adaptive Compression — a volume can look 0% and be saving 2.9:1

On AFF, the inline compression that actually does the work is **Auto Adaptive Compression**. It is
accounted for in the volume's *footprint*, not in the SIS counters. `volume efficiency show` and the
`sis-space-saved*` / `compression-space-saved*` fields cover **volume-level dedupe and compression
only**, so a volume carrying heavy AAC savings reports zero.

Measured case, an Oracle archive-log volume:

```
volume show -volume <vol> -fields sis-space-saved,sis-space-saved-percent,compression-space-saved
    sis-space-saved           39.26MB
    sis-space-saved-percent   0%
    compression-space-saved   0B         <-- reads as "efficiency is doing nothing here"
```

The same volume, asked properly:

```
volume show-footprint -vserver <svm> -volume <vol>
    Volume Data Footprint                                  1.75TB
    Total Footprint                                        1.82TB
    Footprint Data Reduction by Auto Adaptive Compression  1.21TB     <-- ~2.9:1
    Total Deduplication Footprint                          10.08GB
    Effective Total after Footprint Data Reduction         625.6GB
```

Dedupe really was worthless on that data (10 GB of footprint, 39 MB saved). Compression was saving
**1.21 TB**. Acting on the first output alone would disable compression on a volume where it returns
almost 3:1, and the volume would then grow roughly three times faster with no warning: existing
blocks are not rehydrated, so the loss appears only in new writes, weeks later.

**Rule: never conclude a volume saves nothing from `volume efficiency show`.** Check
`volume show-footprint` and read `Footprint Data Reduction by Auto Adaptive Compression` before
turning anything off. Aggregate-wide the same split shows in
`aggr show-efficiency -aggregate <aggr>`, where `Volume Compression Savings ratio` counts only the
SIS path and can sit near 1.03:1 while AAC is doing multiples of that underneath.

### SnapMirror destinations: settings are shown, efficiency state is `Disabled`, AAC still applies

A DP destination reports `state: Disabled` because efficiency *operations* cannot run while it is a
destination, yet its settings stay populated and compression is still applied to what arrives:

```
volume efficiency show -vserver <dest-svm> -volume <vol> \
    -fields state,compression,inline-compression,storage-efficiency-mode,inline-dedupe
    state                    Disabled
    compression              true
    inline-compression       true
    storage-efficiency-mode  efficient
    inline-dedupe            false
```

So there is nothing to "also run" on the destination after changing efficiency on the source, and
attempting it is rejected. Confirm the destination is benefiting with `show-footprint` on that copy
instead. In the measured case the destination reported **780.9 GB** of AAC savings against the
source's 1.21 TB on an identical 1.82 TB footprint. The two copies differ because of snapshot block
sharing, not because compression behaves differently.
