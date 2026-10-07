# SnapMirror S3 Stops Replicating Silently After an Admin-SVM Route Change — Known Issue

## Symptoms
- The destination bucket's object count **stops moving**, while the source keeps changing. In the observed case it stayed frozen for 19 days, with nobody noticing.
- `snapmirror show` looks exactly like a working relationship, because **for a continuous (S3) policy it always looks like this**:

```
# Source cluster                         # Destination cluster
Mirror State: Snapmirrored               Mirror State: Snapmirrored
Relationship Status: Transferring        Relationship Status: Idle
Healthy: false                           Healthy: -
Unhealthy Reason: -   Lag Time: -        (every transfer field is "-")
```

- No EMS event, no unhealthy reason, no transfer error.
- From the **intercluster** LIFs, the destination S3 data LIF does not answer a ping, while the intercluster gateway does. A ping from the cluster-management LIF still succeeds, through its own default route, which hides the problem.
- Not a side effect, despite the timing: about 9 days after replication stopped, every PutObject on the source bucket started returning **503 "Reduce your request rate"**. Restoring replication did **not** fix it, so it's a separate issue. See [Open question](#open-question-source-put-503).

## Environment
- ONTAP 9.16.1P5, SnapMirror S3 with the `Continuous` policy, cluster to cluster. NetApp support confirmed the same path is used same-cluster (case from the original setup).
- The intercluster LIFs and the S3 data LIFs are in different subnets, with a stateful firewall between them.
- An OpenShift (or any other) client subnet shares the subnet of the destination S3 LIF and talks to the source **cluster-management** LIF.

## Root Cause
SnapMirror S3 traffic leaves from the **intercluster LIFs of the admin SVM** and goes to the destination **S3 data LIF** over HTTPS. When the S3 LIF is in another subnet, the admin SVM needs a route to it through the intercluster gateway. That route was the fix in the original NetApp setup case.

The route had been created **subnet-wide** (`<s3-subnet>/24 via <ic-gateway>`). Later, a firewall rule let a client subnet (the same /24) reach the cluster-management LIF on 443. The request arrived through the firewall on the management path. ONTAP's reply matched the /24 route and left through the intercluster gateway instead, so the reply took a different path from the request (**asymmetric routing**). The firewall logged every session as `incomplete` / `aged-out`, and the client got REST errors from that one cluster only.

To fix the client, the /24 route was deleted. That restored the client and **silently cut SnapMirror S3 off**. The newest object on the destination bucket is from 5 seconds before the `route delete` in the audit log.

## Diagnosis

```
# 1. Are the two buckets drifting apart? (compare counts over a few minutes)
vserver object-store-server bucket show -vserver <src_svm> -fields object-count,logical-used
vserver object-store-server bucket show -vserver <dst_svm> -fields object-count,logical-used

# 2. Status the docs actually use for continuous relationships (healthy/lag are meaningless)
snapmirror show -policy-type continuous -fields status

# 3. Can EVERY intercluster LIF reach the destination S3 LIF? (mgmt LIF success proves nothing)
network interface show -vserver <admin_svm> -service-policy default-intercluster -fields lif,address
network ping -vserver <admin_svm> -lif <ic_lif> -destination <dst_s3_lif_ip>
network route show -vserver <admin_svm>

# 4. When did it stop? The audit log keeps months; `event log show` ~12 h (full EMS history: SPI /etc/log/ems.log.*, weeks).
#    The EMS files show the outage directly: fabriclink.retry.delay "store is inaccessible" starts at the route change and stops at the fix.
security audit log show -input *route*create*|*route*delete* -fields timestamp,username,input,state
```

To date the cutoff exactly, list both buckets once each and diff them by key. The newest destination object marks the stop time, and every source-only object is newer than it. See [s3-client-operations.md](../.github/skills/s3-management/references/s3-client-operations.md#diff-two-buckets-and-date-the-replication-cutoff).

## Fix — verified
Use **/32 host routes** only for the S3 LIFs. Never a subnet-wide route, so every other host in that subnet keeps returning through the management gateway.

```
# Source admin SVM -> destination S3 LIF
network route create -vserver <src_admin_svm> -destination <dst_s3_lif_ip>/32 -gateway <ic_gateway> -metric 5

# Destination admin SVM -> source S3 LIF(s)  (failback / resync path, and it stops flaky pings)
network route create -vserver <dst_admin_svm> -destination <src_s3_lif_ip>/32 -gateway <ic_gateway> -metric 5
```

Verify:
1. All intercluster LIFs on both sides ping the remote S3 LIF(s).
2. The destination object count starts climbing within a minute. Observed: about 60 objects/s, with the deletes that never replicated applied too.
3. The client that needed the firewall rule still works, e.g. `curl https://<cluster_mgmt>/api/cluster` from the client returns 401 quickly.

Firewall prerequisites, from the original setup case: TCP 22, 443, 9443, 11104 and 11105 **plus ICMP**, in both directions between the intercluster subnet and the S3 LIFs. Replication only started once ICMP was allowed.

## Prevention
- Document every /32 S3 route as "required for SnapMirror S3", and why, so a future cleanup does not delete it.
- Monitor the object-count delta between source and destination buckets. Relationship health will never alert for S3.
- Before adding a firewall rule for a new client subnet, check whether any admin-SVM route already covers that subnet through a non-management gateway.

## Open question: source PUT 503
The source bucket rejected every PutObject (and initiate-multipart) with 503 in under 1 ms, starting 9 days after replication stopped. GET, LIST and DELETE kept working. Ruled out: FlexGroup inode limit (~9% used), space, snapshots, QoS, config changes, and the ONTAP 9.8 multipart KB. `wafl.zombie.susp.vol.limit` throttling after a mass delete was real, but it stopped while the 503s continued. **Resolved as a separate issue:** after the route fix the destination fully caught up, and the 503s were unchanged two days later, so the replication backlog was **not** the cause. Continued in [s3-put-503-css-error-12-stale-fabriclink.md](s3-put-503-css-error-12-stale-fabriclink.md) (S3 sktrace shows CSS error 12; stale FabricLink object-store configs are the lead).

## Related
- NetApp KB: *Why do I always see S3 SnapMirror in transferring status with object counts* (Transferring is expected; objects wait in the queue until the RPO is met)
- ONTAP docs: *Create a mirror relationship for a new ONTAP S3 bucket on the remote cluster* (verify with `snapmirror show -policy-type continuous -fields status`)
- [S3 Management skill](../.github/skills/s3-management/SKILL.md)
