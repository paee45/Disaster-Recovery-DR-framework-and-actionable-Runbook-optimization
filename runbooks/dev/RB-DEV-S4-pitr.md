# RB-DEV-S4 — Point-in-Time Restore (DEV)

| Field | Value |
|---|---|
| Version / owner | v1.0-draft / `{{TEAM}}` · Reviewed: SRE lead · Approved: CTO · Gate approver: Team lead |
| Before → after | `app-pg-dev` → **`app-pg-dev-p<YYYYMMDDHHMM>`** becomes primary (or a side instance for copying data back) |
| Endpoint | Full cutover: **new** → [CP-01](../common/CP-01-secret-endpoint-cutover.md). Side instance: unchanged |
| RPO / RTO targets | 24 h (expected: minutes; 7-day restore window) / 30 min (aim) |

**Use when:** a broken migration/test/data load in DEV, an accidental delete, or the instance is lost with backups retained.

```bash
source env/dev.env && source automation/scripts/dr-lib.sh && dr_init S4
export OLD_DB=$PRIMARY_DB RESTORED_DB="${PRIMARY_DB}-p$(date -u +%Y%m%d%H%M)"
```

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P1-S01 | Team channel post. Stop the offending job/migration. `dr_mark T1`, `dr_mark T0 --at <bad change>` | Engineer | 3 | Posted |
| P1-S02 | `RESTORE_TS` = bad change − 1 s (or `--use-latest-restorable-time` if the instance is lost); check the window: `aws rds describe-db-instance-automated-backups --db-instance-identifier $PRIMARY_DB --query 'DBInstanceAutomatedBackups[0].RestoreWindow'` | Engineer | 5 | Inside the window |
| P1-G1 ⛳ | Team lead OK; choose full cutover vs side instance. `dr_mark T2` | Team lead | 2 | Recorded |
| P2-S01 | `dr_mark T4` · `./automation/scripts/dr-restore.sh pitr "$PRIMARY_DB" "$RESTORED_DB" "$RESTORE_TS"` | Engineer | 2 | API 200 |
| P2-S02 | `./automation/scripts/dr-restore.sh wait "$RESTORED_DB"` (records `T5`) → `harden` (converge to the baseline + `validate` = `VALIDATED`) → `dr_set_target "$RESTORED_DB"`; `05-restore-point-check.sql` | Engineer | size | Bad change absent |
| P3-S01 | **Side instance:** copy the needed rows back (`pg_dump --data-only -t …` → restore into `$PRIMARY_DB`), then delete RESTORED_DB (`--skip-final-snapshot` is acceptable in DEV) | Engineer | 30 | Repaired |
| P3-S02 | **Full cutover:** CP-04 F1 on OLD_DB → [CP-01](../common/CP-01-secret-endpoint-cutover.md) S04–S07, S09 → `T6`, `T7` → [CP-02](../common/CP-02-post-recovery-verification.md) S01, S03, S04 → `T9`/`T10` | Engineer | 20 | Pods on RESTORED_DB |
| P4-S01 | Evidence (`dr-collect-evidence.sh`); full cutover → raise [RB-DEV-FB-S3S4](RB-DEV-FB-S3S4-post-restore-cleanup.md) | Engineer | 5 | Done |
