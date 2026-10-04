# 04 — RPO & RTO Measurement Framework

## 1. Canonical timeline (every event is machine-recorded)

All events are appended to `timeline.jsonl` by `dr_mark` ([`automation/scripts/dr-lib.sh`](../automation/scripts/dr-lib.sh)),
by SSM step outputs, or by the incident platform. **Use UTC ISO-8601 only.**

| Marker | Event | Source of the timestamp |
|---|---|---|
| **T0** | Impact start (first failed customer request / synthetic check) | Synthetic monitor / ALB 5xx metric. Back-filled from metrics, **not** from when the alarm was noticed |
| T_det | Detection (first alarm fired) | Alarm state-change timestamp |
| T_ack | On-call acknowledged | Paging tool |
| **T1** | DR assessment declared (SEV1) | Incident tool |
| **T2** | Gate G1 = GO | `aws:approve` / incident tool |
| T3 | Fencing complete | `dr_mark` |
| **T4** | Promotion started (API call) | CloudTrail `PromoteReadReplica` / `FailoverGlobalCluster` `eventTime` |
| **T5** | DB writable (`pg_is_in_recovery() = false`, write probe OK) | `dr-verify.sh db` |
| T6 | DNS/secret switched | CloudTrail `ChangeResourceRecordSets`, `PutSecretValue` |
| T7 | All critical Deployments `rollout status` complete | `dr-eks-rollout.sh` |
| T8 | Traffic routed to Region B (Gate G3) | ARC `UpdateRoutingControlState` / R53 change |
| **T9** | **Service restored**: synthetic business transaction green for 3 consecutive runs | Synthetic monitor |
| T10 | Declared stable (Gate G4) | Incident tool |

## 2. RTO: definitions

| Metric | Formula | Use |
|---|---|---|
| **Business RTO (reported against SLA)** | `T9 − T0` | The number that is compared to the RTO target |
| Detection time (MTTD) | `T_det − T0` | Alerting quality |
| Decision time | `T2 − T1` | Governance / clarity of gates (often the biggest share) |
| Technical failover time | `T5 − T4` | DB tech choice (RDS vs Aurora) |
| App recovery time | `T9 − T5` | Secret sync, rollouts, pools, DNS caching |
| Runbook execution time | `T10 − T2` | Automation level |

> **Optimization insight:** in most first-baseline drills, *decision time* and *app recovery time* are larger
> than the DB promotion itself. Break RTO down into these parts before you optimise anything.

## 3. RPO: definitions and how to measure it precisely

`RPO_actual = T_failure_commit − T_last_replicated_commit`

where `T_failure_commit` is the time the primary stopped accepting commits. Measure it with **three independent methods**
and report the worst one:

### Method 1 — Heartbeat table (most precise, recommended)
A tiny job (K8s CronJob or `pg_cron`) writes to the primary every second:
```sql
-- automation/sql/00-heartbeat.sql
INSERT INTO dr.heartbeat(id, ts) VALUES (1, clock_timestamp())
ON CONFLICT (id) DO UPDATE SET ts = EXCLUDED.ts;
```
After promotion, on the new primary:
```sql
SELECT ts AS last_replicated_commit FROM dr.heartbeat WHERE id = 1;
```
`RPO_actual = (last successful heartbeat write logged by the writer job) − dr.heartbeat.ts on the new primary`.
The writer job logs every successful commit, so the "failure" side comes from its logs (CloudWatch Logs / Loki).

### Method 2 — Replica replay timestamp (at the moment of promotion)
Run on the replica **immediately before** promotion (`automation/sql/10-preflight-replica.sql`):
```sql
SELECT now() AS observed_at,
       pg_last_wal_receive_lsn()  AS receive_lsn,
       pg_last_wal_replay_lsn()   AS replay_lsn,
       pg_last_xact_replay_timestamp() AS last_replayed_commit,
       now() - pg_last_xact_replay_timestamp() AS replay_delay;
```
Note: `replay_delay` grows when the primary is idle. That is why Method 1 is preferred.

### Method 3 — CloudWatch metrics (trend and alerting)
| Engine | Metric | Meaning |
|---|---|---|
| RDS PG replica | `ReplicaLag` (seconds, on the replica) | Approximate replication delay |
| RDS PG primary | `OldestReplicationSlotLag`, `TransactionLogsDiskUsage` | WAL backlog risk |
| Aurora Global | `AuroraGlobalDBReplicationLag` (ms), `AuroraGlobalDBRPOLag` (ms) | Storage-level lag / RPO lag |

Alarm: `ReplicaLag > 0.5 × RPO for 5 min` → page. A replica that lags beyond RPO is a **live RPO breach risk**,
not just a warning.

```bash
aws cloudwatch get-metric-statistics --region eu-central-1 \
  --namespace AWS/RDS --metric-name ReplicaLag \
  --dimensions Name=DBInstanceIdentifier,Value=app-pg-prod-euc1 \
  --start-time "$(date -u -d '-30 min' +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" \
  --period 60 --statistics Maximum
```

### Data-loss inventory (when RPO > 0)
Record the **last replayed LSN** on the replica at promotion. When Region A comes back, run a
logical diff or use the WAL beyond that LSN on the old primary to identify lost transactions
(Phase 5, reconciliation). Never delete the old primary until the business has signed off on
reconciliation. Take a manual snapshot first.

## 4. Automated calculation

[`automation/scripts/dr-rto-rpo-calc.py`](../automation/scripts/dr-rto-rpo-calc.py) reads `timeline.jsonl` and
outputs `rto-rpo-report.json` plus a Markdown summary, which go into the evidence bundle and the drill report.

## 5. Evidence query set

| What | Command / query |
|---|---|
| Promotion API call | `aws cloudtrail lookup-events --region eu-central-1 --lookup-attributes AttributeKey=EventName,AttributeValue=PromoteReadReplica` |
| Aurora failover | `... AttributeValue=FailoverGlobalCluster` (or `SwitchoverGlobalCluster`) |
| DNS change | `aws cloudtrail lookup-events --region us-east-1 --lookup-attributes AttributeKey=EventName,AttributeValue=ChangeResourceRecordSets` (Route 53 is a global service, so its events are logged in us-east-1) |
| Secret change | `... AttributeValue=PutSecretValue` in the DR region |
| RDS events | `aws rds describe-events --region eu-central-1 --source-type db-instance --source-identifier app-pg-prod-euc1 --duration 360` |
| Lag history | CloudWatch `ReplicaLag` / `AuroraGlobalDBRPOLag` (above) |
| Rollouts | `kubectl rollout status` / `kubectl get events --sort-by=.lastTimestamp` |
| Prometheus (if used) | `max_over_time(pg_replication_lag_seconds{instance="app-pg-prod-euc1"}[30m])`, `kube_deployment_status_replicas_available{namespace="app"}` |
| Logs Insights: first DB error in app | `fields @timestamp, @message \| filter @message like /could not connect\|read-only transaction/ \| sort @timestamp asc \| limit 1` |
