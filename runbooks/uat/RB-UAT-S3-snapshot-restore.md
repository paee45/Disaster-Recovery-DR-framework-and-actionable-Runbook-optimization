# RB-UAT-S3 — Restore from Daily Snapshot (UAT)

| Field | Value |
|---|---|
| Version / owner / approver | v1.0-draft / `{{SRE_OWNER}}` / SRE on-call + QA lead (+ project lead if UAT test data is lost) |
| Before → after | `app-pg-uat` (+ replica) → **`app-pg-uat-r<YYYYMMDDHHMM>`** (single-AZ) becomes primary |
| Endpoint | **New** → [CP-01](../common/CP-01-secret-endpoint-cutover.md) → ESO → Reloader |
| RPO / RTO (example) | ≤ 24 h (daily snapshot) / ≤ 4 h |
| Also used for | **Planned UAT data reset** to a known snapshot (e.g. a "golden" pre-test-cycle snapshot): same steps, planned comms |

**Use when:** PITR is not possible or not wanted (instance + automated backups gone, a state older than retention, or a reset to a named snapshot).
Otherwise prefer [RB-UAT-S4](RB-UAT-S4-pitr.md).

```bash
source env/uat.env && source automation/scripts/dr-lib.sh && dr_init S3
export OLD_DB=$PRIMARY_DB RESTORED_DB="${PRIMARY_DB}-r$(date -u +%Y%m%d%H%M)"
```

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P1-S01 | Open the incident/change (SEV3) + channel; `dr_mark T1`, `dr_mark T0 --at <impact>` | SRE on-call | 3 | Open |
| P1-S02 ‖ | UAT users / projects email ([Investigating] or the planned-reset notice), stating which test data will be lost (everything after the snapshot time) | QA lead | 10 | Sent |
| P1-S03 | List snapshots: `./automation/scripts/dr-restore.sh list-snapshots $PRIMARY_DB`; choose `SNAPSHOT_ID` | DBA | 5 | Chosen; loss window known |
| P1-G1 ⛳ | GO + data-loss acceptance (SRE on-call + QA lead). `dr_mark T2` | SRE on-call | 5 | Recorded |
| P2-S01 | `dr_run src-config aws rds describe-db-instances --db-instance-identifier $OLD_DB` | DBA | 1 | Saved |
| P2-S02 | `dr_mark T4` · `./automation/scripts/dr-restore.sh snapshot "$SNAPSHOT_ID" "$RESTORED_DB"` (UAT profile: `MULTI_AZ=false`, so the script passes `--no-multi-az`; SG, parameter group, subnet group, tags are explicit) | Executor | 2 | API 200 |
| P2-S03 ‖ | CP01-S01…S03 (inventory, suspend rotation, suspend CronJobs) | Executor | 3 | Done |
| P2-S04 | `aws rds wait db-instance-available --db-instance-identifier $RESTORED_DB`; `dr_set_target "$RESTORED_DB"`; `dr_mark T5` | Executor | size | available |
| P2-S05 | [CP-03](../common/CP-03-restored-instance-config-parity.md) S01–S02; [CP-02](../common/CP-02-post-recovery-verification.md) S02 restore-point check | DBA + QA | 15 | OK |
| P3-S01 | [CP-04](../common/CP-04-fencing-old-instance.md): snapshot OLD_DB, then F1 (F2 later) | DBA | 3 | Fenced |
| P3-S02 | [CP-01](../common/CP-01-secret-endpoint-cutover.md) S04–S09 (**password check**; RO secret → RESTORED_DB, since the old replica follows OLD_DB) → `T6`, `T7` | Executor | 10 | Consumers on RESTORED_DB |
| P4-S01 | [CP-02](../common/CP-02-post-recovery-verification.md) S01, S03–S08 (QA smoke suite) → `T9`, `T10`; [Services Restored] email | QA lead | 30 | Pass |
| P4-S02 | [CP-05](../common/CP-05-evidence-and-closure.md) (`dr_mark RPO_SNAPSHOT "value=<SnapshotCreateTime>"`); raise [RB-UAT-FB-S3S4](RB-UAT-FB-S3S4-post-restore-normalisation.md); PIR if unplanned | Scribe | 15 | Done |
