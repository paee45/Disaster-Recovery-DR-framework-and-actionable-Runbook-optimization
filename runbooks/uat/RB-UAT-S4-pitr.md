# RB-UAT-S4 — Point-in-Time Restore (UAT)

| Field | Value |
|---|---|
| Version / owner | v1.0-draft / `{{SRE_OWNER}}` · Reviewed: SRE lead · Approved: CTO · Gate approvers: SRE on-call + QA lead |
| Modes | **A — full cutover** to `app-pg-uat-p<YYYYMMDDHHMM>` (single-AZ) · **B — surgical repair** (side instance, copy rows back, no cutover) |
| Endpoint | A: **new** → [CP-01](../common/CP-01-secret-endpoint-cutover.md). B: unchanged |
| RPO / RTO targets | 24 h (expected: minutes; 7-day restore window) / 30 min (at risk for mode A, R3) |

**Use when:** bad data in UAT (failed migration test, a broken test-data load, accidental delete) **or** the primary is lost with
backups retained and the replica is unusable. **Never promote the replica for a data problem** (it holds the same damage).

```bash
source env/uat.env && ./automation/scripts/dr-env-check.sh S4   # must PASS before starting
source automation/scripts/dr-lib.sh && dr_init S4
export OLD_DB=$PRIMARY_DB RESTORED_DB="${PRIMARY_DB}-p$(date -u +%Y%m%d%H%M)"
```

**Step by step with the runner (recommended):** `./automation/scripts/dr-run.sh S4` runs this runbook in order with the same step IDs.
For each step it shows the command, the live output (indented), ✅/❌ with the time taken, the timeline markers written and the evidence
files created; it stops at every ⛳ gate for a typed `GO` + approver names, asks the inputs (T0, BAD_TS/RESTORE_TS, mode, E2E reference) once,
prints `dr_phase` time vs budget and syncs the evidence to S3 at each phase end. A failed step stops the run (or `[r]etry`/`[s]kip`);
steps that depend on it are **blocked**, never run. Continue later with `--resume <DR_ID>`. `--list` shows the steps, `--dry-run` the commands,
`--to <ID>` stops early (e.g. `--to P3A-S01` = restore + verify, no cutover). Logs: `evidence/<DR_ID>/run.log`, `steps/<ID>.log`, `run-report.md`.
Runner-only rows (not in the table below): `P0-S01..S03` (env check, pre-flight, names), `P2-G3` ⛳ restore point signed off, `P3A-G0` ⛳ cutover GO; P3A-S04 is split into `P3A-S04` connections, `P3A-S05` E2E → T9, `P3A-G5` ⛳ declare → T10. Mode B: the runner stops after `P3B-S01` (manual repair, confirmed by name).
The table stays the manual procedure: use it when you run the commands yourself.

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P1-S01 | Open the incident (SEV3) + channel; `dr_mark T1`, `dr_mark T0 --at <first bad change>` | SRE on-call | 3 | Open |
| P1-S02 | Stop the damage (pause the job/migration/test data loader; F1 on OLD_DB if the damage is ongoing). `dr_mark DAMAGE_STOPPED` | QA lead + SRE | 5 | Stopped |
| P1-S03 | Find `BAD_TS` (migration logs, CloudWatch PostgreSQL logs, CloudTrail) and check the restore window (`describe-db-instance-automated-backups … RestoreWindow`) | DBA | 10 | `RESTORE_TS = BAD_TS − 1 s` |
| P1-S04 | Choose the mode: **B** if the damage is limited to known tables and other teams' newer UAT data must survive; else **A** | DBA + QA lead | 5 | `DECISION: mode=…` |
| P1-G1 ⛳ | GO (SRE on-call + QA lead) with `RESTORE_TS` and the loss window. `dr_mark T2`. Email the UAT users | SRE on-call | 5 | Recorded / sent |
| P2-S01 | `dr_mark T4` · `./automation/scripts/dr-restore.sh pitr "$PRIMARY_DB" "$RESTORED_DB" "$RESTORE_TS"` | Executor | 2 | API 200 |
| P2-S02 | `./automation/scripts/dr-restore.sh wait "$RESTORED_DB"` (progress + elapsed time; records `T5`), then `./automation/scripts/dr-restore.sh harden "$RESTORED_DB"` (converge to the baseline + `validate`; gate before cutover); `dr_set_target "$RESTORED_DB"`; `dr_mark T5` | Executor | size | available |
| P2-S03 | Restore-point check `05-restore-point-check.sql` (bad change absent) | DBA + QA | 10 | Signed off |
| P3B-S01 | **Mode B:** export the affected tables/rows from RESTORED_DB (`pg_dump --data-only -t …` / `\copy`), apply a reviewed repair script on `$PRIMARY_DB` in one transaction; release F1; delete RESTORED_DB after 3 days | DBA | 30 | Data repaired; T9/T10 via CP-02 |
| P3A-S01 | **Mode A:** [CP-03](../common/CP-03-restored-instance-config-parity.md) S01–S02 | DBA | 10 | Parity OK |
| P3A-S02 | **Mode A:** [CP-04](../common/CP-04-fencing-old-instance.md) (snapshot OLD_DB, F1) | DBA | 3 | Fenced |
| P3A-S03 | **Mode A:** [CP-01](../common/CP-01-secret-endpoint-cutover.md) S04–S09 (password check; RO secret → RESTORED_DB) → `T6`, `T7` | Executor | 10 | Consumers moved |
| P3A-S04 | **Mode A:** [CP-02](../common/CP-02-post-recovery-verification.md) → `T9`, `T10`; [Services Restored] email | QA lead | 30 | Pass |
| P4-S01 | [CP-05](../common/CP-05-evidence-and-closure.md) (`dr_mark RPO_RESTORE_TS "value=$RESTORE_TS"`); mode A → raise [RB-UAT-FB-S3S4](RB-UAT-FB-S3S4-post-restore-normalisation.md); PIR | Scribe | 15 | Done |
