# RB-PROD-S2 — Read Replica Promotion (PROD)

| Field | Value |
|---|---|
| Version / owner | v1.0-draft / `{{SRE_OWNER}}` · Reviewed: SRE lead · Approved: CTO · Gate approvers: IC + SRE lead (CTO if data loss is material) |
| Topology before → after | `app-pg-prod` (Multi-AZ, **lost**) + `app-pg-prod-replica` (same region) → **`app-pg-prod-replica` = standalone primary** (single-AZ until CP03-S03). Not a regional-outage solution (risk R1) |
| Endpoint | **Changes** → endpoint update ([CP-01](../common/CP-01-secret-endpoint-cutover.md): K8s Secret patched directly in `SECRET_MODE=k8s`, or Secrets Manager + ESO in `eso` mode) → **Reloader** |
| Targets | RPO target 24 h (expected = replica lag, usually seconds) · RTO target **30 min** (`T9 − T0`) — achievable only with a fast G1 (≤ 10 min) |
| Automation | SSM `DR-RdsPromoteReplica` (pre-check → G2 approval → promote → wait → secret update via `DR-UpdateDbSecretEndpoint` = **`eso` mode**; in `k8s` mode use the scripts: `dr-verify.sh wait-promoted` + `dr-secret-cutover.sh apply`) |
| Pre-approved change | `{{CHG}}` |

**Use when:** the primary is unavailable and Multi-AZ did not recover it within 5 min (or both AZs/the storage are impaired), **and**
the data on the replica is correct.
**Do NOT use for:** bad data / corruption (the replica has it too) → [RB-PROD-S4](RB-PROD-S4-pitr.md). Multi-AZ failover still in
progress → [RB-PROD-S1](RB-PROD-S1-multiaz-failover-post-event.md).

```bash
source env/prod.env && source automation/scripts/dr-lib.sh && dr_init S2
dr_set_target "$REPLICA_DB"           # exports TARGET_DB/TARGET_DSN (replica endpoint) and OLD_DB/OLD_DSN
```

## Phase 1 — Pre-flight & decision (budget 15 min)

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P1-S01 | Declare SEV1; open `#inc-<date>-prod-rds`, bridge; assign IC, Executor, 2nd eyes, DBA, Comms, Scribe; pin this runbook. `dr_mark T1` | IC | 3 | Roles assigned |
| P1-S02 ‖ | [Investigating] comms: chat now; leadership + status page ≤ 30 min ([templates](../../templates/communications/)) | Comms | 5 | Logged |
| P1-S03 | Set **T0** from the first failing synthetic / 5xx: `dr_mark T0 --at <ts> source=<monitor>` | App owner | 2 | Recorded |
| P1-S04 | Confirm the scenario: RDS events + status of `$PRIMARY_DB`; no Multi-AZ failover in progress or it failed; **data is correct** (not a corruption incident) | DBA | 3 | `DECISION: scenario S2` |
| P1-S05 | Pre-flight: `dr_run preflight ./automation/scripts/dr-preflight.sh replica` (replica `available` + `replicating`/`error`, `ReplicaLag` vs RPO, LSN/heartbeat SQL, creds work on the replica, EKS + Reloader healthy (+ ESO in `eso` mode), host keys present in the K8s Secret, consumer inventory) | Executor | 3 | `PRE-FLIGHT: PASS`, or a waiver per FAIL |
| P1-G1 ⛳ | **Declare DR (IC + SRE lead; CTO if the estimated loss is material)**. GO if the primary is not recoverable within (RTO − measured promote+cutover time) | IC | 5 | `DECISION: G1 GO est_loss=<s>` · `dr_mark T2` |

## Phase 2 — Promotion (budget 15 min)

> Preferred: start the SSM automation right after G1; it pauses at G2.
> ```bash
> aws --profile $AWS_PROFILE --region $AWS_REGION ssm start-automation-execution --document-name DR-RdsPromoteReplica --parameters \
>  "ReplicaDbInstanceId=$REPLICA_DB,SecretId=$SECRET_ID,DrId=$DR_ID,BackupRetentionDays=7,Approvers=arn:aws:iam::$ACCOUNT_ID:role/DRApproverRole,MinRequiredApprovals=2" \
>  --query AutomationExecutionId --output text | tee "$DR_EVIDENCE_DIR/aws/ssm-execution-id.txt"
> ```
> SSM performs P2-S05/S06 and the secret update (CP01-S05). The executor still does the K8s side (CP01-S06/S07).

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P2-S01 ‖ | **Fence OLD_DB** ([CP-04](../common/CP-04-fencing-old-instance.md)) level **F2 quarantine SG** if the API accepts it; otherwise record a waiver: `dr_mark FENCE "level=none waiver=<reason>"` | Executor + 2nd eyes | 3 | Fenced or waiver recorded |
| P2-S02 ‖ | CP01-S01…S03: consumer inventory, **suspend rotation**, **suspend CronJobs** | Executor | 3 | Done |
| P2-S03 | **Capture the final replica state** (RPO evidence): `dr_run replica-final psql "$TARGET_DSN" -XAt -f automation/sql/10-preflight-replica.sql` | DBA | 1 | LSN + last replay ts + heartbeat saved |
| P2-G2 ⛳ | **Point of no return (IC + DBA)**: fence status accepted, final LSN captured. Approve in SSM (`aws:approve`) | IC + DBA | 2 | Approval recorded |
| P2-S04 ‖ | [Failover Initiated] comms, all audiences | Comms | 5 | Logged |
| P2-S05 ⚠ | **Promote** (manual fallback): `dr_mark T4` · `aws --profile $AWS_PROFILE --region $AWS_REGION rds promote-read-replica --db-instance-identifier $REPLICA_DB --backup-retention-period 7` | Executor + 2nd eyes | 1 | API 200 |
| P2-S06 | **Wait until standalone**: `./automation/scripts/dr-verify.sh wait-promoted`. ⚠ Do not trust `wait db-instance-available` alone: the instance can still show `available` *before* the promotion starts. The script waits for: no `ReadReplicaSourceDBInstanceIdentifier` + `available` + `pg_is_in_recovery()=f`. `dr_mark T5` | Executor | 5–15 | `PROMOTED` |

## Phase 3 — Secret cutover & EKS reload (budget 10 min)

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P3-S01 | [CP-01](../common/CP-01-secret-endpoint-cutover.md) S04 → S09: pre-verify creds on TARGET_DB → cutover gate (= **G3**) → update the endpoint (**every key in `K8S_HOST_KEY`** → TARGET_DB, recorded under the DR id; eso mode: `$SECRET_ID` + ESO force-sync) → **Reloader rollouts** → **RO secret** (k8s: `CUTOVER_SECRET=ro TARGET_DB=$TARGET_DB ./automation/scripts/dr-secret-cutover.sh apply`; eso: `SECRET_ID=$SECRET_ID_RO …`; it points at TARGET_DB because there is no replica now) → unannotated consumers. Marks `T6`, `T7` | Executor | 10 | All consumers on TARGET_DB |
| P3-S02 | If OLD_DB was **not** fenced: check it for app sessions now (`dr-verify.sh connections`) and fence as soon as it becomes reachable | DBA | 2 | 0 sessions on OLD_DB |

## Phase 4 — Verification & stabilisation

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P4-S01 | [CP-02](../common/CP-02-post-recovery-verification.md) (S01, S03–S07). `dr_mark T9`, G4 → `T10`. [Services Restored] comms | App + DBA | 15 | Restored |
| P4-S02 | [CP-03](../common/CP-03-restored-instance-config-parity.md) parity + **Multi-AZ conversion (CP03-S03) the same day** + alarm re-pointing + baseline snapshot | DBA + SRE | 30 | Parity diff empty; `MultiAZ=true` |
| P4-S03 | ⚠ **Residual risk:** PROD has **no read replica** until [RB-PROD-FB-S2](RB-PROD-FB-S2-rebuild-replica-and-ha.md). Do FB-S2 phase 1 (create the replica) **within 24 h** | IC | — | FB change raised |
| P4-S04 | [CP-05](../common/CP-05-evidence-and-closure.md) evidence + KPIs; [CP-06](../common/CP-06-post-incident-review.md) PIR | Scribe / IC | 15 | Uploaded / booked |

## Abort / rollback points
| Point | Reversible? | How |
|---|---|---|
| Before P2-S05 | Yes | Un-fence OLD_DB (`dr-fence-instance.sh restore`), resume CronJobs, re-enable rotation |
| After P2-S05 | **No** | The replica is standalone. "Rollback" = [FB-S2 option B](RB-PROD-FB-S2-rebuild-replica-and-ha.md) |
| After CP01-S05 (secret) | Yes, **only** if OLD_DB is intact and nothing important was written to TARGET_DB | `dr-secret-cutover.sh rollback` |

## Change log
| Version | Date | Change | Trigger |
|---|---|---|---|
| 1.0-draft | `{{date}}` | Initial | Capstone |
