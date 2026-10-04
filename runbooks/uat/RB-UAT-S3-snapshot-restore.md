# RB-UAT-S3 — Restore from Daily Snapshot (UAT)

| Field | Value |
|---|---|
| Version / owner | **v1.1** / `{{SRE_OWNER}}` · Reviewed: SRE lead · Approved: CTO · Gate approvers: SRE on-call + QA lead |
| Before → after | `app-pg-uat` (+ replica) → **`app-pg-uat-r<YYYYMMDDHHMM>`** (single-AZ) becomes primary |
| Endpoint | **New** → [CP-01](../common/CP-01-secret-endpoint-cutover.md): secret update → ESO → **Reloader** restarts every pod using the DB secret |
| Targets | RPO 24 h (daily automated snapshot, 7-day retention) · **RTO 30 min** |
| Last exercise | **2026-08-04**: RTO **39 min 55 s (not met)**, RPO 17 h (met), DB 590 MB. Findings → [corrective action plan](../../docs/10-corrective-action-plan-2026-08-04.md) |
| Also used for | Planned UAT data reset to a known snapshot; DR exercises (see §Exercise failback) |

**Use when:** PITR is not possible or not wanted (instance + automated backups gone, a reset to a named snapshot, a DR exercise).
Otherwise prefer [RB-UAT-S4](RB-UAT-S4-pitr.md) (better RPO).

**Time budget (sum = 30 min):** prepare 3 · restore 12 (measured for ~0.6 GB; re-measure if the DB grows) · harden + verify DB 4 · cutover 5 · app verification 5 · close 1.
Each phase prints its elapsed time against the budget (`dr_phase`).

## 0. Before you start (do this once per session — not on the RTO clock)

```bash
cd <repo> && git pull                              # latest approved runbook + scripts
cp -n env/uat.env.example env/uat.env               # first time only; then edit values
source env/uat.env
./automation/scripts/dr-env-check.sh S3             # MUST say ENV CHECK: PASS (catches wrong account/context/placeholders)
source automation/scripts/dr-lib.sh && dr_init S3   # prints every variable that will be used
export OLD_DB="$PRIMARY_DB"                         # the instance being replaced (explicit — TICKET-103)
export RESTORED_DB="${PRIMARY_DB}-r$(date -u +%Y%m%d%H%M)"
echo "OLD_DB=$OLD_DB  RESTORED_DB=$RESTORED_DB"
```
Use **CLI commands from this runbook only**, not the AWS Console (exercise finding: the CLI was faster and more consistent).
Copy commands from the Git/wiki view, not from the form tool.

## Phase 1 — Prepare (budget 3 min)

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P1-S01 | `dr_mark T0 --at <first DB connection error, UTC>`; `dr_mark T1`; `dr_phase start prepare 3`. Post [Investigating] in the internal channel (exercise: the [drill broadcast](../../templates/communications/05-planned-drill-notices.md) **C**) | SRE | 1 | Markers written; message posted |
| P1-S02 | Choose the snapshot: `./automation/scripts/dr-restore.sh list-snapshots $PRIMARY_DB`. Take the **newest `automated`** snapshot unless told otherwise: `export SNAPSHOT_ID=<id>` | SRE | 1 | `SNAPSHOT_ID` set; its create time = RPO reference |
| P1-G1 ⛳ | GO (SRE on-call + QA lead): accept the loss of UAT data after the snapshot time. `dr_mark T2`; `dr_phase end prepare 3` | SRE on-call | 1 | `DECISION:` posted |

## Phase 2 — Restore (budget 12 min + 4 min)

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P2-S01 | `dr_phase start restore 12` · `./automation/scripts/dr-restore.sh snapshot "$SNAPSHOT_ID" "$RESTORED_DB"`. The script copies **all** security groups, the parameter group, subnet group and class from `$OLD_DB` (or the profile), prints them, and records `T4` + `RPO_SNAPSHOT` | SRE | 1 | Table shows `creating`; printed `sgs=[…]` lists **every** SG of the old instance |
| P2-S02 ‖ | While it restores: [CP-01](../common/CP-01-secret-endpoint-cutover.md) S01–S03: `./automation/scripts/dr-eks-rollout.sh inventory` (lists every workload using `$K8S_SECRET`), suspend rotation, `./automation/scripts/dr-eks-rollout.sh suspend-cronjobs` | SRE | 3 | Inventory saved; all consumers `reloader=YES` (else note them for manual restart) |
| P2-S03 | **Wait until available** (do not continue before): `./automation/scripts/dr-restore.sh wait "$RESTORED_DB"`. It prints the status and elapsed time every 30 s and records `T5` when `available`. Then `dr_phase end restore 12` | SRE | ~10 | `available` |
| P2-S04 | `dr_phase start harden 4` · `dr_set_target "$RESTORED_DB"` · `./automation/scripts/dr-restore.sh harden "$RESTORED_DB"`: sets backup retention (7 d), deletion protection, waits, then prints the **parity diff** vs `$OLD_DB` | SRE | 2 | `retention: 7`, all SGs present, parity diff empty except expected rows |
| P2-S05 | **DB verification (core only):** `./automation/scripts/dr-secret-cutover.sh precheck` (app login works) · `dr_run db-post psql "$TARGET_DSN" -f automation/sql/20-postfailover-verify.sql` · `dr_run counts ./automation/scripts/dr-verify.sh compare-counts` (tables from `VERIFY_TABLES`) · `dr_phase end harden 4` | SRE / Backend | 2 | Login OK · all `OK` · counts present |

## Phase 3 — Cutover (budget 5 min)

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P3-S01 | `dr_phase start cutover 5` · [CP-04](../common/CP-04-fencing-old-instance.md): the old instance is already stopped/unreachable in an exercise. In a real event: `./automation/scripts/dr-fence-instance.sh readonly $OLD_DB` | SRE | 1 | Fenced, or noted "stopped" |
| P3-S02 | **Cutover:** `./automation/scripts/dr-secret-cutover.sh apply`. It updates `$SECRET_ID` host → ESO force-sync → checks `$K8S_HOST_KEY` in the K8s Secret → waits for **Reloader** to restart every consumer (manual restart fallback) → `T6`, `T7`. If `SECRET_ID_RO` is used: `SECRET_ID=$SECRET_ID_RO ./automation/scripts/dr-secret-cutover.sh apply` | SRE | 4 | `CUTOVER DONE`; every consumer `rolled out` |
| P3-S03 | `./automation/scripts/dr-eks-rollout.sh resume-cronjobs` · `dr_phase end cutover 5` | SRE | — | CronJobs resumed |

## Phase 4 — Application verification (budget 5 min)

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P4-S01 | `dr_phase start app-verify 5` · `./automation/scripts/dr-verify.sh connections` (app sessions on the new DB, 0 on the old) | SRE | 1 | As expected |
| P4-S02 | **E2E check per the [E2E validation playbook](../../templates/reports/e2e-validation-playbook.md)**: dashboard reachable + **one successful test transaction**. No extra checks (e.g. user-login verification) unless the playbook lists them | Backend | 3 | Transaction ID recorded. `dr_mark T9` at success |
| P4-G4 ⛳ | Declare restored: `dr_mark T10` · `dr_phase end app-verify 5` · `dr_summary` (post it) · [Services Restored] message | SRE on-call | 1 | RTO = T9 − T0 shown |

## Phase 5 — Close (budget 1 min on the clock; the rest afterwards)

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P5-S01 | `./automation/scripts/dr-collect-evidence.sh` (timeline, phase times, CloudTrail, RDS events, secret version metadata, rollouts, SQL outputs, KPI report, SHA-256 manifest). All outputs carry **UTC timestamps** | SRE | 1 | `EVIDENCE: … sha256=…` posted |
| P5-S02 | Real event: raise [RB-UAT-FB-S3S4](RB-UAT-FB-S3S4-post-restore-normalisation.md). Exercise: run §Exercise failback | SRE | — | Done |

## Exercise failback (exercise only; not on the RTO clock)

Returns UAT to the original instance after an exercise. It is safe because nothing important was written to the restored DB.

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| XF-S01 | Start the original instance if it was stopped: `aws rds start-db-instance --db-instance-identifier $OLD_DB` then `./automation/scripts/dr-restore.sh wait $OLD_DB` | SRE | ~5 | `available` |
| XF-S02 | `dr_phase start failback` · switch back: `./automation/scripts/dr-secret-cutover.sh rollback` (AWSPREVIOUS → AWSCURRENT; Reloader restarts the pods) | SRE | 4 | Consumers on `$OLD_DB` |
| XF-S03 | Post-failback check: `TARGET_DB=$OLD_DB ./automation/scripts/dr-verify.sh connections` + the E2E playbook (dashboard + one test transaction) · `dr_phase end failback` | Backend | 3 | Pass |
| XF-S04 | Remove the restored instance: `aws rds modify-db-instance --db-instance-identifier $RESTORED_DB --no-deletion-protection --apply-immediately` then `aws rds delete-db-instance --db-instance-identifier $RESTORED_DB --skip-final-snapshot` | SRE | 1 | Deleting |
| XF-S05 | Re-enable rotation if it was suspended; `./automation/scripts/dr-collect-evidence.sh` again (adds the failback records); fill in the [exercise report](../../templates/reports/drill-report.md) | SRE | 10 | Report draft |

## Troubleshooting
See [CP-07 troubleshooting](../common/CP-07-troubleshooting.md) (restore stuck, missing SG, login failure after restore, pods not restarted, ESO not syncing).

## Change log
| Version | Date | Change | Trigger |
|---|---|---|---|
| 1.0-draft | 2026-10 | Initial | Capstone |
| 1.1 | `{{date}}` | Explicit variables, env check, wait/harden steps, all SGs + retention, phase timers, slim verification, exercise failback, CLI-only | Exercise 2026-08-04 (TICKET-101…108) |
