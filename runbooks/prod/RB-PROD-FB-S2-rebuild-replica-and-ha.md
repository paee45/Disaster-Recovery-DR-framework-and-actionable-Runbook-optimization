# RB-PROD-FB-S2 — Post-Promotion Failback: Rebuild Replica & HA (PROD)

| Field | Value |
|---|---|
| Type | Planned change(s) after RB-PROD-S2. Phase 1 **within 24 h** (restores DR protection); later phases in a maintenance window |
| Start state | `TARGET_DB` (= former replica) is the primary; OLD_DB is fenced; there is no replica; Multi-AZ per CP03-S03 |
| End state | The original topology again: **Multi-AZ primary + read replica**, IaC in sync, monitoring and rotation on, OLD_DB decommissioned |

## Choose the failback model (Gate FB-G0, SRE lead + DBA; CTO approves option B)

| Option | When | Downtime | Recommendation |
|---|---|---|---|
| **A — Forward-fix (keep the promoted instance as primary)** | Default. The identifier/endpoint does not matter to apps, because the secret holds it | **None** (no second cutover) | ✅ Recommended |
| **B — Return to an original instance/identifier** | Policy/tooling hard-codes the identifier, or the instance class/placement must return | One planned write outage (≈ 5–15 min) + secret cutover | Only if required |

```bash
source env/prod.env && source automation/scripts/dr-lib.sh && dr_init FB-S2
export OLD_DB=app-pg-prod NEW_PRIMARY=app-pg-prod-replica     # adjust to the actual names after S2
dr_set_target "$NEW_PRIMARY"
```

## Phase 1 — Restore DR protection (≤ 24 h after S2, both options)

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P1-S01 | Confirm Multi-AZ on the new primary (CP03-S03) is complete | DBA | 1 | `MultiAZ=true` |
| P1-S02 | **Create a new read replica** from the new primary: `aws rds create-db-instance-read-replica --db-instance-identifier app-pg-prod-replica2 --source-db-instance-identifier $NEW_PRIMARY --db-instance-class $DB_INSTANCE_CLASS --db-subnet-group-name $DB_SUBNET_GROUP --vpc-security-group-ids $DB_SG --db-parameter-group-name $DB_PARAM_GROUP --deletion-protection --copy-tags-to-snapshot --enable-performance-insights --tags Key=dr-role,Value=replica` (cross-region: add `--region $REPLICA_REGION --source-region $AWS_REGION --kms-key-id <key-in-replica-region>` and use the ARN as the source) | DBA | 5 (+ build time) | `available`, `replicating`, `ReplicaLag` ≈ 0 |
| P1-S03 | Repoint the **RO secret** to the new replica: `TARGET_DB=app-pg-prod-replica2 SECRET_ID=$SECRET_ID_RO ./automation/scripts/dr-secret-cutover.sh apply` → Reloader rolls the reader pods | Executor | 5 | Reader pods on the replica |
| P1-S04 | Heartbeat writer (`automation/k8s/heartbeat-writer.yaml`) writes to the new primary (it follows the secret via Reloader); replica heartbeat age < 10 s | SRE | 2 | `DRHeartbeatStale` OK |
| P1-S05 | Re-run the pre-flight against the new pair: `REPLICA_DB=app-pg-prod-replica2 ./automation/scripts/dr-preflight.sh replica` | Executor | 3 | PASS → **DR posture restored** |

## Phase 2 — Data reconciliation (if RPO > 0 or fencing was waived)

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P2-S01 | Snapshot OLD_DB (if not done in CP04-S01). Start it **fenced** (quarantine SG + bastion-only rule) | DBA | 10 | Snapshot available |
| P2-S02 | Find writes on OLD_DB after the last replicated point: `psql "$OLD_DSN" -v cutoff="'<RPO_LAST_REPLICATED>'" -f automation/sql/30-reconciliation-hints.sql` | DBA | 30 | Candidate rows exported (CSV → evidence) |
| P2-S03 | The business owner decides re-apply / discard per data set; apply via a reviewed script to the new primary | App owner + DBA | — | Signed reconciliation report |

## Phase 3A — Option A: normalise (no downtime)

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P3A-S01 | [CP-03](../common/CP-03-restored-instance-config-parity.md) full: parity, monitoring re-point, **re-enable rotation**, AWS Backup tag, **IaC adoption** (primary resource → `$NEW_PRIMARY`, replica resource → `app-pg-prod-replica2`) | SRE + DBA | 60 | `terraform plan` clean |
| P3A-S02 | *(Optional, cosmetic)* Rename identifiers. ⚠ A rename **changes the endpoint**, so it needs the [CP-01](../common/CP-01-secret-endpoint-cutover.md) cutover in a maintenance window. Usually skip it and keep the names in IaC/CMDB | DBA | — | Decision recorded |
| P3A-S03 | Decommission OLD_DB after the reconciliation sign-off + retention (e.g. 14 days): `aws rds modify-db-instance --db-instance-identifier $OLD_DB --no-deletion-protection --apply-immediately` then `aws rds delete-db-instance --db-instance-identifier $OLD_DB --final-db-snapshot-identifier ${OLD_DB}-final-$(date -u +%Y%m%d)` | DBA | 5 | Final snapshot kept per retention policy |

## Phase 3B — Option B: planned switch back (maintenance window)

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P3B-S01 | Planned-maintenance comms (T−10 business days customers, T−5 partners) | Comms | — | Sent |
| P3B-S02 | Ensure the destination instance is a **replica of the current primary** (e.g. `app-pg-prod-replica2` sized and placed as required) with lag ≈ 0 | DBA | — | Ready |
| P3B-S03 | **Drain**: scale writers to 0 / maintenance mode; CP-04 F1 on the current primary; `automation/sql/15-planned-drain.sql` until `bytes_behind = 0` | DBA | 10 | RPO = 0 |
| P3B-S04 ⚠ | Promote the destination replica (`promote-read-replica`), wait-promoted, then [CP-01](../common/CP-01-secret-endpoint-cutover.md) to its endpoint, then [CP-02](../common/CP-02-post-recovery-verification.md). ⚠ Run `ALTER DATABASE app SET default_transaction_read_only = off` on the new primary (F1 is replicated) | Executor + DBA | 20 | Restored |
| P3B-S05 | Re-establish Multi-AZ + a new replica (repeat Phase 1), CP-03, decommission the superseded instance | DBA | — | Original topology |

## Closure
CP-05 evidence (`type=failback`), close the change, [Post-Mortem / RCA Ready] comms if the PIR is complete.
