# RB-DEV-S3 — Restore from Daily Snapshot (DEV)

| Field | Value |
|---|---|
| Version / owner | v1.0-draft / `{{TEAM}}` · Reviewed: SRE lead · Approved: CTO · Gate approver: Team lead |
| Topology | **Single primary only** (no Multi-AZ, no replica). Snapshot/PITR restore is the **only** recovery path in DEV |
| Before → after | `app-pg-dev` → **`app-pg-dev-r<YYYYMMDDHHMM>`** becomes primary |
| Endpoint | **New** → [CP-01](../common/CP-01-secret-endpoint-cutover.md): endpoint written into the K8s Secret (`SECRET_MODE=k8s`; or via Secrets Manager + ESO in `eso` mode) → **Reloader** restarts the pods |
| RPO / RTO targets | 24 h (daily automated snapshot, 7-day retention) / 30 min (aim) |
| Also used for | DEV data refresh / reset |

DEV is where the **automation is tested** (scripts, SSM documents, Reloader behaviour) before it is used in UAT/PROD.

```bash
source env/dev.env && ./automation/scripts/dr-env-check.sh S3   # must PASS before starting
source automation/scripts/dr-lib.sh && dr_init S3
export OLD_DB=$PRIMARY_DB RESTORED_DB="${PRIMARY_DB}-r$(date -u +%Y%m%d%H%M)"
```

**Step-by-step runner:** `./automation/scripts/dr-run.sh S3` executes the restore with live output, evidence per step, gates and `--resume` (step IDs follow [RB-UAT-S3](../uat/RB-UAT-S3-snapshot-restore.md); `--list` maps them). This table remains the authoritative manual procedure.

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P1-S01 | Post in the team channel ([Investigating], DEV short form). `dr_mark T1`, `dr_mark T0 --at <impact>` | Engineer | 2 | Posted |
| P1-S02 | Check whether PITR is possible (better RPO) → [RB-DEV-S4](RB-DEV-S4-pitr.md). Otherwise list snapshots: `./automation/scripts/dr-restore.sh list-snapshots $PRIMARY_DB` and choose `SNAPSHOT_ID` | Engineer | 5 | Chosen |
| P1-G1 ⛳ | Team lead OK (data after the snapshot time is lost). `dr_mark T2` | Team lead | 2 | Recorded |
| P2-S01 | `dr_mark T4` · `./automation/scripts/dr-restore.sh snapshot "$SNAPSHOT_ID" "$RESTORED_DB"` (settings from the captured source baseline; preview first with `dr-restore.sh plan snapshot …`) **or** SSM `DR-RdsRestoreFromSnapshot` with `MinRequiredApprovals=1` (exercises the PROD automation path) | Engineer | 2 | API 200 |
| P2-S02 | `./automation/scripts/dr-restore.sh wait "$RESTORED_DB"` (progress + elapsed time; records `T5`), then `./automation/scripts/dr-restore.sh harden "$RESTORED_DB"` (converge to the baseline + `validate`); `dr_set_target "$RESTORED_DB"`; `dr_mark T5` | Engineer | size | available |
| P2-S03 | `./automation/scripts/dr-restore.sh validate "$RESTORED_DB"` (all settings vs baseline) | Engineer | 2 | `VALIDATED` |
| P3-S01 | [CP-04](../common/CP-04-fencing-old-instance.md) F1 on OLD_DB (if it is alive) | Engineer | 2 | Fenced |
| P3-S02 | [CP-01](../common/CP-01-secret-endpoint-cutover.md) S04–S07, S09 (password check, **endpoint update** — k8s mode: every host key patched in the K8s Secret + change recorded; eso mode: Secrets Manager + ESO sync — **Reloader rollouts**) → `T6`, `T7` | Engineer | 10 | Pods on RESTORED_DB |
| P4-S01 | [CP-02](../common/CP-02-post-recovery-verification.md) S01, S03, S04 → `T9`/`T10`; post [Services Restored] in the team channel | Engineer | 10 | OK |
| P4-S02 | `./automation/scripts/dr-collect-evidence.sh` (30-day retention prefix); record the restore duration (feeds the RTO model) | Engineer | 5 | Uploaded |
| P4-S03 | Raise [RB-DEV-FB-S3S4](RB-DEV-FB-S3S4-post-restore-cleanup.md) | Engineer | 1 | Ticket |
