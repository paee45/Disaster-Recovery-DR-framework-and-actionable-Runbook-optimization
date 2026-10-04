# RB-PROD-FB-S3S4 — Post-Restore Normalisation / Failback (PROD)

| Field | Value |
|---|---|
| Type | Planned change(s) after RB-PROD-S3 or RB-PROD-S4 mode A. **Phase 1 within 24 h** |
| Start state | `RESTORED_DB` (`-r…`/`-p…`) is the Multi-AZ primary; OLD_DB + the old replica are fenced; there is no replica for the new primary |
| End state | Multi-AZ primary + **new read replica**, parity, monitoring, rotation, backups, IaC in sync; old instances decommissioned after reconciliation |

There is no "switch back" to OLD_DB: it holds the damaged or lost state. "Failback" here means **returning to the
standard topology and operations**. Keeping the new identifier is recommended (the secret holds the endpoint, so apps do not care).

```bash
source env/prod.env && source automation/scripts/dr-lib.sh && dr_init FB-S3S4
export OLD_DB=app-pg-prod OLD_REPLICA=app-pg-prod-replica NEW_PRIMARY=<RESTORED_DB>
dr_set_target "$NEW_PRIMARY"
```

## Phase 1 — Restore DR protection (≤ 24 h)

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P1-S01 | `MultiAZ=true` on NEW_PRIMARY (set at restore; otherwise CP03-S03) | DBA | 1 | true |
| P1-S02 | **New read replica**: `aws rds create-db-instance-read-replica --db-instance-identifier ${NEW_PRIMARY}-replica --source-db-instance-identifier $NEW_PRIMARY --db-instance-class $DB_INSTANCE_CLASS --db-subnet-group-name $DB_SUBNET_GROUP --vpc-security-group-ids $DB_SG --db-parameter-group-name $DB_PARAM_GROUP --deletion-protection --enable-performance-insights --copy-tags-to-snapshot` | DBA | 5 (+ build) | `replicating`, lag ≈ 0 |
| P1-S03 | RO secret → new replica: `TARGET_DB=${NEW_PRIMARY}-replica SECRET_ID=$SECRET_ID_RO ./automation/scripts/dr-secret-cutover.sh apply` (Reloader rolls the readers) | Executor | 5 | Readers on the new replica |
| P1-S04 | Pre-flight on the new pair: `PRIMARY_DB=$NEW_PRIMARY REPLICA_DB=${NEW_PRIMARY}-replica ./automation/scripts/dr-preflight.sh replica` | Executor | 3 | PASS |

## Phase 2 — Operational normalisation

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P2-S01 | [CP-03](../common/CP-03-restored-instance-config-parity.md) complete: parity, alarms/dashboards/event subscriptions re-pointed, Datadog/Prometheus config, **re-enable rotation**, AWS Backup selection tag, baseline snapshot | SRE + DBA | 60 | All green |
| P2-S02 | **CDC/ETL consumers** (DMS, Debezium, logical replication, BI extracts) re-initialised against NEW_PRIMARY; downstream partners informed of the data rollback window | Data owner | — | Consumers healthy |
| P2-S03 | **IaC adoption** (CP-03 §3): primary → NEW_PRIMARY, replica → `${NEW_PRIMARY}-replica`; `state rm` the old resources | SRE | 30 | `terraform plan` clean |
| P2-S04 | Update the CMDB / runbook env profile (`env/prod.env`: `PRIMARY_DB`, `REPLICA_DB`) via a PR, so the **next** incident uses the right names | SRE | 5 | PR merged |

## Phase 3 — Decommission (after reconciliation sign-off + retention, e.g. 14–30 days)

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P3-S01 | Confirm the reconciliation sign-off (S3/S4 P3A-S06) and CTO/ISMS hold status (security incidents may require keeping the instance/snapshot as evidence, ISO 27001 A.5.28) | IC | — | Approved |
| P3-S02 | Delete the old replica, then OLD_DB, with final snapshots: `aws rds modify-db-instance --db-instance-identifier <id> --no-deletion-protection --apply-immediately`; `aws rds delete-db-instance --db-instance-identifier <id> --final-db-snapshot-identifier <id>-final-$(date -u +%Y%m%d)` (replicas: `--skip-final-snapshot` is allowed, since replicas cannot have one) | DBA | 10 | Deleted; final snapshot retained per policy |
| P3-S03 | *(Optional)* identifier rename in a maintenance window → endpoint changes → [CP-01](../common/CP-01-secret-endpoint-cutover.md). Usually skipped | DBA | — | Decision recorded |
| P3-S04 | CP-05 evidence (`type=failback`), close the change; [Post-Mortem / RCA Ready] comms | Scribe / Comms | 10 | Closed |
