# RB-PROD-S3 — Restore from Daily Snapshot (PROD)

| Field | Value |
|---|---|
| Version / owner | v1.0-draft / `{{SRE_OWNER}}` · Reviewed: SRE lead · Approved: CTO · G1 data-loss acceptance: **CTO** (data loss is certain) |
| Before → after | `app-pg-prod` (+ replica) → new instance **`app-pg-prod-r<YYYYMMDDHHMM>`** (Multi-AZ) becomes primary |
| Endpoint | **New** → [CP-01](../common/CP-01-secret-endpoint-cutover.md) secret cutover → ESO → Reloader |
| RPO | Target **24 h** = incident time − `SnapshotCreateTime` of the daily automated snapshot (kept **7 days**) |
| RTO | Target 30 min — ⚠ **at risk**: restore time scales with DB size and is not yet measured (risk R3) + parity + cutover + warm-up |
| Automation | SSM `DR-RdsRestoreFromSnapshot` (restore → wait → G3 approval → `DR-UpdateDbSecretEndpoint`) |

**Use when (and only when PITR cannot do it better):**
- the instance and its automated backups are gone (deleted without retained backups, account/region issue), or
- PITR fails or a clean daily point is explicitly preferred, or
- **security event**: restore into a clean VPC with rotated credentials (IR lead = IC). Note: there is **no cross-account backup copy** today (risk R5).

> Automated snapshots are only kept for **7 days**. Older states exist only if a manual snapshot was taken (risk R4).
Otherwise → [RB-PROD-S4 PITR](RB-PROD-S4-pitr.md) (RPO in minutes instead of hours).

```bash
source env/prod.env && ./automation/scripts/dr-env-check.sh S3   # must PASS before starting
source automation/scripts/dr-lib.sh && dr_init S3
export OLD_DB=$PRIMARY_DB
export RESTORED_DB="${PRIMARY_DB}-r$(date -u +%Y%m%d%H%M)"
```

## Phase 1 — Assess, choose the snapshot (budget 20 min)

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P1-S01 | Declare SEV1, roles, channel. `dr_mark T1`; `dr_mark T0 --at <impact start>` | IC | 3 | Open |
| P1-S02 ‖ | [Investigating] comms. Prepare the **data-restore variant** of the customer template (wording reviewed by SRE lead, approved by CTO) | Comms | 10 | Draft approved |
| P1-S03 | **Confirm PITR is not possible / not better**: `aws rds describe-db-instance-automated-backups --db-instance-identifier $PRIMARY_DB --query 'DBInstanceAutomatedBackups[0].RestoreWindow'` | DBA | 2 | Reason recorded |
| P1-S04 | **List candidate snapshots** (automated daily `rds:…` within 7 days, plus any manual ones): `./automation/scripts/dr-restore.sh list-snapshots $PRIMARY_DB` | DBA | 3 | Table: id, type, create time, encrypted/KMS |
| P1-S05 | **Pick the snapshot**: the latest one *before* the incident (for a data/security incident: before the first bad change/IOC). Note `SnapshotCreateTime` → est. data loss | DBA + App owner | 5 | `SNAPSHOT_ID` + data-loss window |
| P1-G1 ⛳ | **Declare restore + accept data loss** (IC + SRE lead; **CTO** accepts the data loss): `DECISION: G1 GO snapshot=<id> loss_window=<from>-<to>` · `dr_mark T2` | IC | 5 | Recorded |

## Phase 2 — Restore (budget = size-dependent)

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P2-S01 | Save the source config for parity: `dr_run src-config aws rds describe-db-instances --db-instance-identifier $OLD_DB` (if it still exists; otherwise use the IaC values in `env/prod.env`) | DBA | 1 | Saved |
| P2-S02 | **Restore** (all hardening flags explicit; the defaults are wrong for PROD): `dr_mark T4` · `./automation/scripts/dr-restore.sh snapshot "$SNAPSHOT_ID" "$RESTORED_DB"` → runs `aws rds restore-db-instance-from-db-snapshot --db-instance-identifier $RESTORED_DB --db-snapshot-identifier $SNAPSHOT_ID --db-instance-class $DB_INSTANCE_CLASS --db-subnet-group-name $DB_SUBNET_GROUP --vpc-security-group-ids $DB_SG --db-parameter-group-name $DB_PARAM_GROUP --multi-az --no-publicly-accessible --deletion-protection --copy-tags-to-snapshot --enable-cloudwatch-logs-exports postgresql upgrade --tags Key=dr-restore,Value=$DR_ID` | Executor + 2nd eyes | 2 | API 200 |
| P2-S03 ‖ | While it restores: **suspend CronJobs + rotation** (CP01-S02/S03); [Failover Initiated] comms ("restoring data to <time>") | Executor / Comms | 5 | Done |
| P2-S04 | Wait: `./automation/scripts/dr-restore.sh wait "$RESTORED_DB"` (progress + elapsed time; records `T5`), then `./automation/scripts/dr-restore.sh harden "$RESTORED_DB"` (backup retention, deletion protection, parity diff) (safe here: it is a new instance). Then `dr_set_target "$RESTORED_DB"`; `dr_mark T5` | Executor | size | `available` |
| P2-S05 | [CP-03](../common/CP-03-restored-instance-config-parity.md) S01–S02: parity diff vs OLD_DB and fix (backup retention, PI, monitoring, CA, IAM auth, tags) **before** cutover | DBA | 10 | Diff empty / accepted |
| P2-S06 | **Validate the restored data**: [CP-02](../common/CP-02-post-recovery-verification.md) S02 (restore-point check; bad data absent) + `20-postfailover-verify.sql` | DBA + App owner | 10 | App owner sign-off |
| P2-S07 | **Warm-up** (lazy loading): `psql "$TARGET_DSN" -f automation/sql/06-warmup.sql` | DBA | 10–60 | Hot tables loaded |

## Phase 3 — Fence & cutover

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P3-S01 | **Fence OLD_DB** ([CP-04](../common/CP-04-fencing-old-instance.md)): snapshot it first (CP04-S01, it is the only copy of the post-snapshot writes), then F1 read-only (F2 after reconciliation extraction) | DBA | 3 | Fenced |
| P3-S02 | **Old replica**: it still follows OLD_DB (stale/bad data). Make sure no reads go there: CP01-S08 points `$SECRET_ID_RO` at RESTORED_DB | Executor | 3 | 0 sessions on the old replica |
| P3-S03 | [CP-01](../common/CP-01-secret-endpoint-cutover.md) S04–S09 (**password check is critical after a restore**), cutover gate = **G3**, `T6`, `T7` | Executor + DBA | 10 | All consumers on RESTORED_DB |

## Phase 4 — Verify & stabilise
| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P4-S01 | [CP-02](../common/CP-02-post-recovery-verification.md) S01, S03–S08 → `T9`, G4 → `T10`. [Services Restored] comms (**data-restore variant**) | App + DBA | 20 | Restored |
| P4-S02 | Monitoring re-point + baseline snapshot (CP03-S04, S06) | SRE | 15 | Alarms OK |
| P4-S03 | ⚠ **No read replica** for the new primary → [RB-PROD-FB-S3S4](RB-PROD-FB-S3S4-post-restore-normalisation.md) Phase 1 within 24 h | IC | — | Change raised |
| P4-S04 | [CP-05](../common/CP-05-evidence-and-closure.md): `dr_mark RPO_SNAPSHOT "value=<SnapshotCreateTime>"`; evidence; [CP-06](../common/CP-06-post-incident-review.md) PIR | Scribe / IC | 15 | Done |

## Abort / rollback
Until CP01-S05 nothing in production has changed: delete or keep RESTORED_DB. After the cutover: `dr-secret-cutover.sh rollback`
(un-fence OLD_DB first) is possible only while you accept losing the writes made on RESTORED_DB since T6.
