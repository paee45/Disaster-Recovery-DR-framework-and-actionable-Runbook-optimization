# RB-PROD-S4 — Point-in-Time Restore (PROD)

| Field | Value |
|---|---|
| Version / owner | v1.0-draft / `{{SRE_OWNER}}` · Reviewed: SRE lead · Approved: CTO · G1 data-loss acceptance: **CTO** |
| Before → after | **Mode A (full cutover):** new instance **`app-pg-prod-p<YYYYMMDDHHMM>`** (Multi-AZ) becomes primary. **Mode B (surgical repair):** a side instance is used only to copy data back; `app-pg-prod` stays primary |
| Endpoint | Mode A: **new** → [CP-01](../common/CP-01-secret-endpoint-cutover.md). Mode B: unchanged |
| RPO | Mode A: incident detection − chosen `restore-time` (writes after the restore time are lost unless reconciled). Mode B: ≈ 0 for unaffected data |
| Restore window | Last **7 days** (backup retention): `EarliestRestorableTime` … `LatestRestorableTime` (usually ≤ 5 min behind now) |
| Targets | RPO target 24 h (expected: minutes) · RTO target 30 min — ⚠ **at risk** for mode A (restore + WAL replay time not measured, risk R3) |
| Automation | SSM `DR-RdsRestoreToPointInTime`; `automation/scripts/dr-restore.sh pitr` |

**Use when:** logical damage (bad migration/deploy, mass delete/update, app bug), or the instance is lost but automated backups
are retained (instance failure, both AZs, accidental deletion with retained backups).
**Prefer S2** if the instance is lost *and* the replica is healthy (smaller RPO, faster). **Never S2 for data damage.**

```bash
source env/prod.env && ./automation/scripts/dr-env-check.sh S4   # must PASS before starting
source automation/scripts/dr-lib.sh && dr_init S4
export OLD_DB=$PRIMARY_DB
export RESTORED_DB="${PRIMARY_DB}-p$(date -u +%Y%m%d%H%M)"
```

## Phase 1 — Assess, find the restore time, choose the mode (budget 20–30 min)

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P1-S01 | Declare SEV1/SEV2, roles, channel. `dr_mark T1`, `dr_mark T0 --at <first bad change or impact>` | IC | 3 | Open |
| P1-S02 | **Stop the damage first**: pause the offending deploy/job/integration (scale it to 0, disable the feature flag, revoke the user). For an ongoing destructive process: CP-04 **F1** on OLD_DB (app becomes read-only, but the damage stops) | App owner + IC | 5 | Damage stopped (`dr_mark DAMAGE_STOPPED`) |
| P1-S03 | **Find the bad change time** (precise to the second): deploy/migration logs, CloudTrail, app audit logs, PostgreSQL logs in CloudWatch Logs (`log_statement=ddl`/`mod`, `log_min_duration_statement`): Logs Insights `fields @timestamp, @message \| filter @message like /DROP\|TRUNCATE\|DELETE FROM <table>/ \| sort @timestamp asc \| limit 20` | DBA | 10 | `BAD_TS` identified, with its source |
| P1-S04 | Restore window: `aws rds describe-db-instance-automated-backups --db-instance-identifier $PRIMARY_DB --query 'DBInstanceAutomatedBackups[0].RestoreWindow'` and `LatestRestorableTime` | DBA | 1 | `BAD_TS` inside the window |
| P1-S05 | **Choose the mode** (IC + DBA + App owner): **B surgical** if the damage is limited to known tables/rows and the rest of the DB must keep its newer writes; **A full** if the damage is wide/unknown or the instance is lost | IC | 5 | `DECISION: mode=A\|B` |
| P1-S06 | **Restore time** = `BAD_TS − 1 s` (for a lost instance: `--use-latest-restorable-time`). Estimate data loss (mode A) = writes between `RESTORE_TS` and `DAMAGE_STOPPED` | DBA | 2 | `RESTORE_TS` |
| P1-G1 ⛳ | **Approve** mode + `RESTORE_TS` + data-loss window (IC + SRE lead; **CTO** accepts the data loss) · `dr_mark T2` | IC | 5 | Recorded |
| P1-S07 ‖ | [Investigating] / [Failover Initiated] comms (**data-restore variant**, wording reviewed by SRE lead / approved by CTO) | Comms | 10 | Logged |

## Phase 2 — PITR restore (both modes)

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P2-S01 | `dr_mark T4` · `./automation/scripts/dr-restore.sh pitr "$PRIMARY_DB" "$RESTORED_DB" "$RESTORE_TS"` → `aws rds restore-db-instance-to-point-in-time --source-db-instance-identifier $PRIMARY_DB --target-db-instance-identifier $RESTORED_DB --restore-time $RESTORE_TS --db-instance-class $DB_INSTANCE_CLASS --db-subnet-group-name $DB_SUBNET_GROUP --vpc-security-group-ids $DB_SG --db-parameter-group-name $DB_PARAM_GROUP --multi-az --no-publicly-accessible --deletion-protection --copy-tags-to-snapshot --enable-cloudwatch-logs-exports postgresql upgrade --tags Key=dr-restore,Value=$DR_ID` (source deleted → `--source-dbi-resource-id` from the retained automated backup; mode B: `--no-multi-az`, smaller class OK) | Executor + 2nd eyes | 2 | API 200 |
| P2-S02 | Wait `./automation/scripts/dr-restore.sh wait "$RESTORED_DB"` (progress + elapsed time; records `T5`), then `./automation/scripts/dr-restore.sh harden "$RESTORED_DB"` (converge to the baseline + `validate`; gate before cutover) (PITR replays WAL: longer if far from a snapshot) · `dr_set_target "$RESTORED_DB"` · `dr_mark T5` | Executor | size | `available` |
| P2-S03 | **Validate the restore point**: `psql "$TARGET_DSN" -v cutoff="'$RESTORE_TS'" -f automation/sql/05-restore-point-check.sql`; the bad change must be **absent**; latest business rows ≈ `RESTORE_TS` | DBA + App owner | 10 | Signed off. If wrong → new PITR with a corrected time (keep the instance for comparison) |

## Phase 3B — Mode B: surgical repair (no cutover)

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P3B-S01 | Extract the good data from RESTORED_DB: `pg_dump "$TARGET_DSN" --data-only -t <schema.table> -Fc -f repair.dump` or `\copy (select … where <affected keys>) to 'rows.csv' csv header` | DBA | 15 | Files in evidence (hash only, if PII → secure location) |
| P3B-S02 | Repair script reviewed by DBA + App owner (four-eyes): `BEGIN; … INSERT … ON CONFLICT … / UPDATE … FROM staging …; -- verify counts; COMMIT;` on the **production** primary (in a transaction, with a row-count assertion) | DBA | 30 | Counts match expectations |
| P3B-S03 | Release the F1 fence if it was applied; resume the paused job/deploy only with the fix | App owner | 5 | Writes resume |
| P3B-S04 | [CP-02](../common/CP-02-post-recovery-verification.md) S01, S04–S07 → T9/T10. Keep RESTORED_DB for **7 days**, then delete it (final snapshot) | DBA | 15 | Restored |

## Phase 3A — Mode A: full cutover

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P3A-S01 | [CP-03](../common/CP-03-restored-instance-config-parity.md) S01–S02 parity (Multi-AZ already set on restore) | DBA | 10 | Diff empty |
| P3A-S02 | Warm-up `automation/sql/06-warmup.sql` | DBA | 10–60 | Done |
| P3A-S03 | **Fence OLD_DB** ([CP-04](../common/CP-04-fencing-old-instance.md)): snapshot first (it holds the writes after `RESTORE_TS`), then F1 → F2 after extraction. The old replica follows OLD_DB (bad data): CP01-S08 for `$SECRET_ID_RO` | DBA | 5 | Fenced |
| P3A-S04 | [CP-01](../common/CP-01-secret-endpoint-cutover.md) S04–S09 (**password check**), cutover gate = **G3** → `T6`, `T7` | Executor | 10 | All consumers on RESTORED_DB |
| P3A-S05 | [CP-02](../common/CP-02-post-recovery-verification.md) → `T9`, G4 → `T10`; [Services Restored] (data-restore variant) | App + DBA | 20 | Restored |
| P3A-S06 | **Reconcile** the writes between `RESTORE_TS` and the fence from OLD_DB (`30-reconciliation-hints.sql`, cutoff = `RESTORE_TS`), excluding the bad change; business decides | DBA + App | — | Signed report |
| P3A-S07 | ⚠ No replica → [RB-PROD-FB-S3S4](RB-PROD-FB-S3S4-post-restore-normalisation.md) Phase 1 ≤ 24 h | IC | — | Change raised |

## Closure
[CP-05](../common/CP-05-evidence-and-closure.md) with `dr_mark RPO_RESTORE_TS "value=$RESTORE_TS"`; [CP-06](../common/CP-06-post-incident-review.md) PIR (S4 questions: how the bad change got in, the guardrails).
