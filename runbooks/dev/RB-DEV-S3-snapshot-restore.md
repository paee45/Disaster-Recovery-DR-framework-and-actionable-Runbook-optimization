# RB-DEV-S3 — Restore from Daily Snapshot (DEV)

| Field | Value |
|---|---|
| Version / owner / approver | v1.0-draft / `{{TEAM}}` / Team lead |
| Topology | **Single primary only** (no Multi-AZ, no replica). Snapshot/PITR restore is the **only** recovery path in DEV |
| Before → after | `app-pg-dev` → **`app-pg-dev-r<YYYYMMDDHHMM>`** becomes primary |
| Endpoint | **New** → [CP-01](../common/CP-01-secret-endpoint-cutover.md) → ESO → Reloader |
| RPO / RTO (example) | ≤ 24 h / ≤ 8 h (business hours) |
| Also used for | DEV data refresh / reset; **monthly automated restore test** (proves backups are restorable and measures restore time) |

DEV is where the **automation is tested** (scripts, SSM documents, Reloader behaviour) before it is used in UAT/PROD.

```bash
source env/dev.env && source automation/scripts/dr-lib.sh && dr_init S3
export OLD_DB=$PRIMARY_DB RESTORED_DB="${PRIMARY_DB}-r$(date -u +%Y%m%d%H%M)"
```

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P1-S01 | Post in the team channel ([Investigating], DEV short form). `dr_mark T1`, `dr_mark T0 --at <impact>` | Engineer | 2 | Posted |
| P1-S02 | Check whether PITR is possible (better RPO) → [RB-DEV-S4](RB-DEV-S4-pitr.md). Otherwise list snapshots: `./automation/scripts/dr-restore.sh list-snapshots $PRIMARY_DB` and choose `SNAPSHOT_ID` | Engineer | 5 | Chosen |
| P1-G1 ⛳ | Team lead OK (data after the snapshot time is lost). `dr_mark T2` | Team lead | 2 | Recorded |
| P2-S01 | `dr_mark T4` · `./automation/scripts/dr-restore.sh snapshot "$SNAPSHOT_ID" "$RESTORED_DB"` (DEV profile: single-AZ; SG/PG/subnets explicit) **or** SSM `DR-RdsRestoreFromSnapshot` with `MinRequiredApprovals=1` (exercises the PROD automation path) | Engineer | 2 | API 200 |
| P2-S02 | `aws rds wait db-instance-available --db-instance-identifier $RESTORED_DB`; `dr_set_target "$RESTORED_DB"`; `dr_mark T5` | Engineer | size | available |
| P2-S03 | `./automation/scripts/rds-config-parity.sh $OLD_DB $RESTORED_DB` (if OLD_DB exists); fix SG/PG/backup retention | Engineer | 5 | OK |
| P3-S01 | [CP-04](../common/CP-04-fencing-old-instance.md) F1 on OLD_DB (if it is alive) | Engineer | 2 | Fenced |
| P3-S02 | [CP-01](../common/CP-01-secret-endpoint-cutover.md) S04–S07, S09 (password check, secret update, ESO force-sync, **Reloader rollouts**) → `T6`, `T7` | Engineer | 10 | Pods on RESTORED_DB |
| P4-S01 | [CP-02](../common/CP-02-post-recovery-verification.md) S01, S03, S04 → `T9`/`T10`; post [Services Restored] in the team channel | Engineer | 10 | OK |
| P4-S02 | `./automation/scripts/dr-collect-evidence.sh` (30-day retention prefix); record the restore duration (feeds the RTO model) | Engineer | 5 | Uploaded |
| P4-S03 | Raise [RB-DEV-FB-S3S4](RB-DEV-FB-S3S4-post-restore-cleanup.md) | Engineer | 1 | Ticket |
