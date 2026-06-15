# Test-WorkspaceHealth.ps1

Comprehensive **read-only** health check for the ONTAP automation workspace and all configured clusters.

## What it checks (36 phases)

| # | Phase | What it does |
|---|-------|-------------|
| 1 | Script Syntax | Parses all `.ps1` files for errors |
| 2 | Config & Functions | Loads `config.json`, verifies auto-generated functions |
| 3 | Modules | Checks `NetApp.ONTAP`, `DataONTAP`, personal modules |
| 4 | External Tools | `ssh`, `git`, `wsl`, `python`, `ansible-playbook` |
| 5 | Credential Store | Decrypts `.cred` files with `aes.key` |
| 6 | Skills | Validates all 12 `SKILL.md` files exist and are non-empty |
| 7 | Knowledge Base | Checks `Netapp Cases/`, `KnownIssues/`, `PDF/` |
| 8 | Connectivity | DNS, TCP/22, TCP/443, SSH `version`, ZAPI `Connect-NcController` |
| 9 | Dependencies | Script root-path resolution |
| 10 | S3 Config | `S3_Config` fields, credential files, vault files |
| 11 | Ansible | Playbook files, vault files, WSL syntax check |
| 12 | S3 Tools | `aws`, `rclone` availability |
| 13 | DFS Config | `DFS_Config` fields, `Find-DFSPath` function |
| 14 | NDMP Config | `NDMP_Config` fields, per-cluster `NdmpPassword` |
| 15 | Git | Branch, remotes, working tree status |
| 16 | Docs Hub | `Docs_Port`, `index.html` |
| 17 | CSV CLI | Smoke test: `vserver show` via `Invoke-OntapCsv` |
| 18 | REST API | Smoke test: `GET /api/cluster` |
| 19 | Template Drift | `config.json` vs `config.template.json` key comparison |
| 20 | Session Logs | `.github/session-log-*.md` freshness |
| 21–36 | Cluster Ops | Per-cluster operational health (see below) |

### Cluster operational checks (phases 21–36)

| Phase | ONTAP command | What it verifies |
|-------|--------------|-----------------|
| SVM State | `vserver show -type data -fields vserver,state` | All data SVMs running |
| Node Health | `cluster show -fields node,health,eligibility` | All nodes healthy |
| Aggregates | `aggr show -fields aggregate,…,percent-used,state` | Utilization below thresholds |
| Volumes | `vol show -fields vserver,volume,percent-used,state` | Utilization below thresholds |
| SnapMirror Health | `snapmirror show -health false` | No unhealthy relationships |
| SnapMirror Lag | `snapmirror show -fields destination-path,lag-time` | Lag below threshold |
| Cluster Faults | `system health alert show` | No critical/error alerts |
| Storage Errors | `storage errors show` | No storage errors |
| Snapshot Policy | `vol show -fields snapshot-policy` | All volumes have a policy |
| iSCSI Sessions | `iscsi session show` | Active sessions on iSCSI SVMs |
| LIF Home Port | `net int show -fields …,is-home,status-oper` | LIFs at home and up |
| HA Failover | `storage failover show` | HA enabled, partners connected |
| Disk Health | `storage disk show -container-type broken/spare` | No broken disks, spares exist |
| Cluster Peers | `cluster peer show -fields availability` | All peers Available |
| Network Ports | `net port show -fields …,health-status` | All ports healthy |
| S3 Server | `vserver object-store-server show` | S3 servers configured (conditional) |

## Safety — what it does NOT do

- **No aggregates created or modified** — only reads `aggr show`
- **No LIFs or IP addresses created** — only reads `net int show` and `net port show`
- **No volumes, LUNs, or qtrees created or modified**
- **No SnapMirror relationships changed** — only reads status
- **No configuration changes of any kind** — every ONTAP command is a `show` command
- **No data written to any cluster** — purely read-only SSH queries

The script runs `show` commands only. It never calls `create`, `modify`, `delete`, or any mutating ONTAP CLI verb.

## Parameters

```
-SkipConnectivity       Skip all network/SSH/cluster checks (local only)
-SkipCredentials        Skip credential decryption tests
-Cluster <name>         Run cluster ops on a single cluster (alias, name, or connect name)
-AggWarnPct <int>       Aggregate % warn threshold (default: 80)
-AggFailPct <int>       Aggregate % fail threshold (default: 90)
-VolWarnPct <int>       Volume % warn threshold (default: 85)
-VolFailPct <int>       Volume % fail threshold (default: 95)
-SnapLagWarnHours <int> SnapMirror lag warn in hours (default: 24)
-SnapLagFailHours <int> SnapMirror lag fail in hours (default: 48)
-OutputDir <path>       Output directory (default: scripts/testing/logs)
```

## Usage

```powershell
# Full check — all clusters, default thresholds
.\scripts\testing\Test-WorkspaceHealth.ps1

# Offline — no cluster connectivity
.\scripts\testing\Test-WorkspaceHealth.ps1 -SkipConnectivity

# Single cluster with custom thresholds
.\scripts\testing\Test-WorkspaceHealth.ps1 -Cluster <ClusterName> -AggWarnPct 75

# Minimal — no connectivity, no credential tests
.\scripts\testing\Test-WorkspaceHealth.ps1 -SkipConnectivity -SkipCredentials
```

## Output

- Console: colorized pass/fail/warn/skip per test
- CSV: `scripts/testing/logs/WorkspaceHealth_<timestamp>.csv`
- Transcript: `scripts/testing/logs/WorkspaceHealth_<timestamp>.log`
- Exit code: `0` = no failures, `1` = at least one failure
