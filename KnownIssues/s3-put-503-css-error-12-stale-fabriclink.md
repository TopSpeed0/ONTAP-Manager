# ONTAP S3 Rejects Every Write with 503 "Reduce your request rate" — CSS Error 12 / Stale FabricLink — Known Issue

> **Status: OPEN.** The root cause is not yet confirmed by NetApp support. This article records the
> diagnosis path and the strongest lead. Update it with the confirmed fix once known.

## Symptoms
- **100%** of `PutObject`, `CopyObject`, `PutObjectTagging` and `InitiateMultipartUpload` on one bucket return **HTTP 503 SlowDown "Reduce your request rate"**. This covers every client and every object size, including 0-byte objects.
- `GetObject`, `ListObjects`, `HeadObject` and `DeleteObject` keep working (200/204/404).
- Each rejection takes **under 1 ms** at a low request rate (~3 PUT/s), so it's a state refusal, not throttling under load.
- The bucket is a **SnapMirror S3 source** (`Is bucket a FabricLink source and protected: true`).
- It persisted for weeks, unchanged after replication was repaired and the destination caught up.

## Environment
- ONTAP 9.16.1P5, AFF, 2-node HA pair, ~425 days uptime
- An S3 bucket on an 8-constituent FlexGroup, protected by continuous SnapMirror S3 to another cluster
- The same SVM had earlier been used for **same-cluster SnapMirror S3 tests**, which left extra object-store configurations behind
- Shortly before onset: a mass delete of ~95M orphaned multipart parts through the S3 API, and a period where the SnapMirror S3 network path was down

## What it is NOT (ruled out with evidence)
| Suspect | Evidence against |
|---|---|
| Inode limit | Busiest constituent at 14% of `files` |
| Space / bucket quota | Constituents ~67% used; bucket below its size |
| Snapshots, QoS, object lock | None configured |
| Configuration change | `security audit log` shows no S3/bucket/volume change near onset |
| The KB "S3 client returns ServiceUnavailable: Reduce your request rate" | That one is ONTAP 9.8 multipart only |
| `wafl.zombie.susp.vol.limit` throttling after the mass delete | Real at onset, but it stopped while the 503s continued |
| SnapMirror S3 backlog | Destination fully caught up; 503s unchanged |

## Diagnosis

### 1. Prove where the 503 comes from: S3 sktrace (NetApp-requested)

```
set -privilege diagnostic
# Record the baseline first — default is Err+Warn ON for these modules
debug sktrace tracepoint show -node <node> | <filter S3, S3_CMD, S3_PCP, S3_AUTH>

debug sktrace tracepoint modify -node * -module S3      -level * -enabled true
debug sktrace tracepoint modify -node * -module S3_CMD  -level * -enabled true
debug sktrace tracepoint modify -node * -module S3_PCP  -level * -enabled true
debug sktrace tracepoint modify -node * -module S3_AUTH -level * -enabled true
# reproduce for 60-90 s (client retries are enough), then:
debug sktrace tracepoint modify -node * -module <each> -level * -enabled false
# restore the baseline: the "disable all" above also turns OFF the default Err/Warn
debug sktrace tracepoint modify -node * -module <each> -level Err  -enabled true
debug sktrace tracepoint modify -node * -module <each> -level Warn -enabled true
system node autosupport invoke -node * -type all -message "<case> S3 sktrace <window>"
```

Signature seen in this case:

```
S3_CMD_Err:    handleCreateObjectFHResponse got back 12 from Dblade      <- every PutObject
S3_Err:        S3Connection::initiateServerSideClose
CSS_EXCEPTION: CSS: Message WAFL_CSS_ALLOC_OBJECT failed for error 12, request id N, volume dsid N   <- every constituent
CSS_EXCEPTION: CSS: Message WAFL_CSS_MULTIPART_INITIATE failed for error 12
WAFLREMOTE_EXCEPTION: Message WAFL_REMOTE_EVICT failed with code 12        <- ~145K lines/s, both nodes
S3_AUTH_Dbg:   Root User: Skipping Group & Bucket Policy access checks    <- (tells you which S3 user the app uses)
```

S3 accepts the request; the **storage layer (CSS/WAFL on the D-blade) refuses the object allocation with error 12**. `READ_OBJECT ... error 2` is plain "not found" and corresponds to the 404s.

### 2. Check FabricLink — the link between a SnapMirror S3 source bucket and its destination

```
# How many object-store configs exist vs how many relationships?
snapmirror object-store config show -vserver <s3_svm> -instance
snapmirror show -source-vserver <s3_svm> -fields source-path,destination-path,policy,relationship-id

# mgwd.log via the SPI: https://<cluster_mgmt>/spi/<node>/etc/log/mlog/mgwd.log
#   grep: "ERR: fabriclink"
```

Seen in this case:
- **3 object-store configs for 1 relationship**:
  - one live;
  - one pointing at a NAS SVM's LIF with an access key that no longer exists;
  - one pointing the SVM **at itself**, with an access key the destination rejects (`InvalidAccessKeyId`).

  The extra two were left over from earlier same-cluster tests.
- `mgwd.log` on both nodes, continuously: `ERR: fabriclink: get_endpoint_types ... Fabriclink ep-type check failed with error: Failed to get information for object store "00000000-0000-0000-0000-000000000000"`.
- EMS on the onset day: `fabriclink.retry.delay` hundreds of times (NOTICE severity, so hidden by default).

### Closest NetApp KB
[S3 Bucket Access Fails with "ServiceUnavailable: Reduce your request rate"](https://kb.netapp.com/on-prem/ontap/da/S3/S3-KBs/S3_Bucket_Access_Fails_with_%E2%80%9CServiceUnavailable%3A_Reduce_your_request_rate%E2%80%9D) (ONTAP 9, S3, SnapMirror). It has the same sktrace family (`S3_CMD_Err: handleListObjectsResponse CSS error:12`) plus `mgwd.log` `fabriclink: replay_link_changes_to_dblade: create_link failed`. The KB's trigger is a broken/promoted SnapMirror S3. Here the relationship was never broken, but stale FabricLink object-store configs exist. The full cause and fix are behind NetApp sign-in.

## Fix
**Not confirmed yet.** Do **not** delete object-store configs or break the SnapMirror S3 relationship on your own. Open a case with the sktrace signature, the object-store config list, and the `mgwd.log` fabriclink errors, and let NetApp confirm which configs are stale and what the FabricLink repair procedure is. Record the confirmed fix here.

## Prevention (independent of the final root cause)
- After a SnapMirror S3 **test**, remove its relationship **and** its `snapmirror object-store config` entries. Deleting the relationship alone leaves the configs behind.
- Keep the root S3 user's keys stable on protected SVMs, and don't leave configs that reference rotated or deleted keys.
- Periodically compare `snapmirror object-store config show` against `snapmirror show` for every S3 SVM. More configs than relationships is a red flag.

## Collection gotchas
See [ontap-observability-gotchas.md](../.github/skills/ontap-cluster-info/references/ontap-observability-gotchas.md) #18–#19: sktrace rotates in seconds, the SPI shows times in America/New_York, and the trace tags are mixed case.

## Related
- [snapmirror-s3-silent-stop-intercluster-route.md](snapmirror-s3-silent-stop-intercluster-route.md): the replication outage that overlapped with this one but turned out to be a separate problem
- [S3 Management skill](../.github/skills/s3-management/SKILL.md)
