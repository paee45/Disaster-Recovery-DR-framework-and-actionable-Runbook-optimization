# 04 — RPO & RTO Measurement Framework

## 1. Canonical timeline (machine-recorded)

Events go to `timeline.jsonl` via `dr_mark` ([`dr-lib.sh`](../automation/scripts/dr-lib.sh)); the scripts mark T6/T7 themselves. **UTC ISO-8601 only.**

| Marker | Event | Source | S1 | S2 | S3/S4 |
|---|---|---|---|---|---|
| **T0** | Impact start (or first bad change for data incidents) | Synthetic/5xx metric, deploy/migration log. Back-filled with `--at` | ✔ | ✔ | ✔ |
| T1 | Incident declared | Incident tool | ✔ | ✔ | ✔ |
| **T2** | Gate G1 GO (scenario + data loss accepted) | `DECISION:` / SSM approval | — | ✔ | ✔ |
| DAMAGE_STOPPED | Offending job/deploy stopped | Engineer | — | — | S4 |
| FENCE | Old instance fenced (level F1/F2/F3) | `dr-fence-instance.sh` | — | ✔ | ✔ |
| **T4** | DB recovery started (failover start / promote / restore API call) | RDS event / CloudTrail | ✔ | ✔ | ✔ |
| **T5** | New primary writable | RDS event (S1), `wait-promoted`, `wait db-instance-available` | ✔ | ✔ | ✔ |
| **T6** | Secret updated (endpoint cutover) | `dr-secret-cutover.sh apply` (auto) | — | ✔ | ✔ |
| **T7** | All consumers rolled by Reloader (or manual restart) | `dr-eks-rollout.sh wait` (auto) | (restart only if needed) | ✔ | ✔ |
| **T9** | **Service restored**: the first of 3 consecutive green synthetic business transactions | Synthetic monitor | ✔ | ✔ | ✔ |
| T10 | Declared restored (G4) | Incident tool | ✔ | ✔ | ✔ |

## 2. RTO

| Metric | Formula | Typical driver |
|---|---|---|
| **Business RTO** (reported vs target) | `T9 − T0` | Everything below |
| Time to declare | `T1 − T0` | Alerting, on-call |
| Decision time | `T2 − T1` | Clarity of gates/approvers. Often the largest share |
| DB recovery time | `T5 − T4` | S1 ≈ 1–2 min; S2 promotion ≈ minutes; **S3/S4 ∝ DB size** (+ WAL replay for PITR) |
| Cutover time | `T7 − T6` | ESO sync + Reloader rollouts (pod start time × waves) |
| Validation time | `T9 − T7` | Smoke tests, warm-up (S3/S4 lazy loading) |

**Build an RTO model per environment** from drills and update it after each one:
`RTO_est(S3/S4) = decision + restore_minutes_per_100GB × size/100 + parity(10) + warm-up + cutover + validation`.
If `RTO_est` > target for PROD S3/S4 → backlog item (smaller DB/archiving, faster storage class, or prefer S2 where valid).

## 3. RPO per scenario

| Scenario | RPO formula | How to measure | Markers |
|---|---|---|---|
| **S1** Multi-AZ | **0** (synchronous standby) | RDS guarantees committed data | `RPO_ZERO` |
| **S2** Replica promotion | last primary commit − last replicated commit | **Heartbeat** (below) + replica LSN capture before promotion | `RPO_LAST_REPLICATED`, `RPO_LAST_PRIMARY_COMMIT` |
| **S3** Snapshot | loss_end − `SnapshotCreateTime` | Snapshot metadata | `RPO_SNAPSHOT` |
| **S4** PITR | loss_end − `restore-time` | The chosen restore time | `RPO_RESTORE_TS` |

`loss_end` = the latest of `T0`, `DAMAGE_STOPPED` and `FENCE`. Writes the old primary accepted after the restore point are
lost **unless reconciled** (`30-reconciliation-hints.sql`). For data-corruption incidents some of that loss is intentional
(the bad change), so report both the "RPO window" and the "records reconciled".

### Heartbeat (S2, UAT/PROD)
`automation/k8s/heartbeat-writer.yaml` writes `dr.heartbeat.ts` every second through the app secret and logs every commit.
- On the promoted DB: `SELECT ts FROM dr.heartbeat WHERE id = 1` → `RPO_LAST_REPLICATED`
- From the writer logs: the last `heartbeat_commit` before the outage → `RPO_LAST_PRIMARY_COMMIT`

### Replica position at promotion (S2)
`automation/sql/10-preflight-replica.sql` captures `pg_last_wal_receive_lsn()`, `pg_last_wal_replay_lsn()` and
`pg_last_xact_replay_timestamp()` right before the promotion. This is the reconciliation cutoff and audit evidence.

### Alarms that protect RPO
| Metric | Alarm |
|---|---|
| `ReplicaLag` (replica, seconds) | > 50 % of RPO for 5 min → page |
| Heartbeat age on replica | > 120 s → page |
| `TransactionLogsDiskUsage`, `OldestReplicationSlotLag` (primary) | WAL backlog growth |
| AWS Backup job failures / missing daily snapshot | Ticket (S3 RPO at risk) |
| `LatestRestorableTime` older than 15 min | Page (S4 RPO at risk) |

## 4. Automated calculation

`dr-rto-rpo-calc.py timeline.jsonl --rto-target-min $RTO_TARGET_MIN --rpo-target-s $RPO_TARGET_S` → `rto-rpo-report.json|md`.
It picks the RPO method from the markers present and lists the missing markers (each one is a runbook-execution defect).

## 5. Evidence query set

| What | Command |
|---|---|
| Recovery API calls | `aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=PromoteReadReplica` (also `RestoreDBInstanceFromDBSnapshot`, `RestoreDBInstanceToPointInTime`, `RebootDBInstance`) |
| Secret cutover | `... AttributeValue=PutSecretValue` / `UpdateSecretVersionStage`; `aws secretsmanager describe-secret --secret-id $SECRET_ID --query VersionIdsToStages` |
| RDS events (S1 failover reason/time) | `aws rds describe-events --source-type db-instance --source-identifier $PRIMARY_DB --duration 1440` |
| Lag history | `aws cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name ReplicaLag --dimensions Name=DBInstanceIdentifier,Value=$REPLICA_DB ...` |
| Restore window | `aws rds describe-db-instance-automated-backups --db-instance-identifier $PRIMARY_DB --query 'DBInstanceAutomatedBackups[0].RestoreWindow'` |
| Rollouts | `k8s/rollout-status-*.txt`, `kubectl get events --sort-by=.lastTimestamp`, Reloader logs (JSON) |
| First DB error in app logs (T0 back-fill) | Logs Insights: `fields @timestamp, @message \| filter @message like /could not connect\|read-only transaction\|terminating connection/ \| sort @timestamp asc \| limit 1` |
