# RB-DR-RDS-001 — RDS PostgreSQL Regional Failover (+ EKS application recovery)

| Field | Value |
|---|---|
| Runbook ID / version | RB-DR-RDS-001 / **v1.0-draft** |
| Service / tier | `{{SERVICE_NAME}}` / T1 |
| Owner / approver | `{{SRE_OWNER}}` / `{{SERVICE_OWNER}}` |
| Environments | UAT, PROD (DEV: automation testing only) |
| Linked automation | SSM doc `DR-RdsPostgresRegionalFailover` v`{{N}}`, scripts @ git `{{SHA}}` |
| Last drill / result | `{{DATE}}` / RTO `{{mm}}` min, RPO `{{ss}}` s (`{{DRILL_REPORT_LINK}}`) |
| Targets | RPO ≤ 5 min · RTO ≤ 60 min (business, `T9 − T0`) |
| Pre-approved emergency change | `{{CHANGE_ID}}` |

---

## 1. When to use / when NOT to use

**Use when:** the primary RDS PostgreSQL instance in Region A (`eu-west-1`) is unavailable or cannot be reached
from the application, **and** in-region HA (Multi-AZ failover) has not restored service or cannot do so within RTO,
**or** for a **planned switchover** (drill / maintenance). Planned switchovers use the ✦ variants (zero data loss).

**Do NOT use when:**
| Situation | Use instead |
|---|---|
| Bad data / logical corruption (replica is also corrupted) | RB-DR-RDS-002 PITR & selective restore |
| Suspected compromise / ransomware | RB-SEC-010 Isolated-account restore (security IR lead is the IC) |
| Single-AZ failure, Multi-AZ failover in progress | Wait (typically 1–2 min), then re-assess |
| Only the EKS cluster is impaired, DB is fine | RB-DR-EKS-001 |

## 2. Roles
IC · Executor · Second pair of eyes (verifies ⚠ steps) · DBA · App owner(s) · Scribe · Comms lead · Exec approver. See [`docs/02 §4`](../docs/02-runbook-standards.md).

## 3. Prerequisites & environment block

Access: assume `DRExecutorRole` in the workload account **via the Region B sign-in path** (break-glass if SSO is impaired).
Run commands from a CloudShell / bastion **in Region B**, or from a laptop with a fresh clone of this repo.

```bash
# ---- ENV BLOCK: the only place values are set. Source it: `source env/prod.env` ----
export DR_ENV=prod                         # dev | uat | prod
export DR_ID="DR-$(date -u +%Y%m%d)-prod-rds"   # incident/drill id (use the incident tool's id if one exists)
export DR_MODE=unplanned                   # unplanned | planned  (planned = zero-data-loss switchover ✦)
export PRIMARY_REGION=eu-west-1
export DR_REGION=eu-central-1
export ACCOUNT_ID=111122223333
export PRIMARY_DB=app-pg-prod-euw1
export DR_DB=app-pg-prod-euc1
export DB_NAME=app
export DB_SG_PRIMARY=sg-0aaaaaaaaaaaaaaaa  # SG attached to the old primary (fencing)
export HOSTED_ZONE_ID=Z0123456789ABCDEFGHIJ  # private zone db.prod.internal (associated with both VPCs)
export DB_CNAME=app-pg.db.prod.internal
export SECRET_ID=prod/app/db
export EKS_PRIMARY=eks-prod-euw1
export EKS_DR=eks-prod-euc1
export K8S_NS=app
export DR_SELECTOR='dr.example.com/tier=critical'   # label on Deployments to restart in order
export EVIDENCE_BUCKET=org-dr-evidence-${ACCOUNT_ID}
export SYNTHETIC_URL=https://app.example.com/healthz/deep
# Alt-Aurora:
export GLOBAL_CLUSTER=app-pg-global
export DR_CLUSTER_ARN=arn:aws:rds:${DR_REGION}:${ACCOUNT_ID}:cluster:app-pg-prod-euc1
```

```bash
source automation/scripts/dr-lib.sh   # provides dr_init, dr_mark, dr_run (logs output into evidence dir)
dr_init                               # creates ./evidence/$DR_ID/, starts timeline.jsonl,
                                      # exports DR_DSN (libpq conninfo for the DR *instance* endpoint,
                                      # credentials pulled from the Region B replica secret)
```

---

## PHASE 1 — Pre-flight & health checks  (budget: 15 min)

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P1-S01 | Declare SEV1 "DR assessment" in the incident tool; open `#inc-<id>-prod-rds-dr` + bridge; assign roles; pin this runbook. `dr_mark T1` | IC | 3 | Channel exists, roles assigned |
| P1-S02 ‖ | Send **[Investigating]** comms: internal chat immediately, customers within 30 min ([templates](../templates/communications/)) | Comms | 5 | Logged in comms log |
| P1-S03 | Confirm impact and set **T0** (first failing synthetic / 5xx spike). `dr_mark T0 --at <ts>` | App owner | 3 | T0 recorded with its source |
| P1-S04 | Confirm the failure class: is the data *corrupt* or is this a *security* event? If **yes → STOP**, switch runbook (§1) | IC + DBA | 2 | Explicit "class A" decision in channel (`DECISION:`) |
| P1-S05 | Check the provider and in-region HA status: AWS Health Dashboard / `aws health describe-events` (us-east-1 endpoint), RDS events for the primary | DBA | 3 | Region-level issue confirmed, or Multi-AZ failover not progressing |
| P1-S06 | Run automated pre-flight: `dr_run preflight ./automation/scripts/dr-preflight.sh` | Executor | 3 | All `PASS`; `WARN`s discussed; output in evidence |

**What the pre-flight checks** (fail = do not proceed without an IC waiver):
1. Replica `$DR_DB` is `available`, is still a replica of `$PRIMARY_DB`, and the replication state is not `error`/`terminated`.
2. `ReplicaLag` (CloudWatch, last 15 min max) is below the RPO, **or** an estimated data loss is reported.
3. SQL on the replica: `pg_is_in_recovery() = true`, receive/replay LSNs, `pg_last_xact_replay_timestamp()`, heartbeat age.
4. Replica secret `$SECRET_ID` exists in `$DR_REGION` and the DB user can authenticate to `$DR_DB`.
5. The DR EKS API is reachable; ExternalSecret `db-creds` has `Ready=True`; DR Deployments exist.
6. The SSM document version in `$DR_REGION` matches the runbook header.

> ### ⛳ GATE G1 — Declare DR (IC + Service Owner; + Exec approver if estimated data loss > RPO)
> GO if: provider ETA unknown or > (RTO − measured failover duration), **and** pre-flight passes or waived.
> Record: `DECISION: G1 GO — <names> — est. data loss <x s> — <reason>` · `dr_mark T2`
> NO-GO: stay in assessment and re-evaluate every 15 min (set a timer in the channel).

---

## PHASE 2 — Database failover execution  (budget: 15 min)

> Preferred: run the SSM Automation (start it right after G1). It runs its own pre-check, pauses at **G2** (`aws:approve`), then performs P2-S06…P2-S08 (promote → wait until standalone → CNAME → wait INSYNC). Do P2-S01…S05 while it waits at G2:
> ```bash
> aws ssm start-automation-execution --region $DR_REGION \
>   --document-name DR-RdsPostgresRegionalFailover \
>   --parameters "DrDbInstanceId=$DR_DB,HostedZoneId=$HOSTED_ZONE_ID,RecordName=$DB_CNAME,DrId=$DR_ID,Approvers=arn:aws:iam::${ACCOUNT_ID}:role/DRApproverRole" \
>   --query AutomationExecutionId --output text | tee -a evidence/$DR_ID/aws/ssm-execution-id.txt
> ```
> Each manual command below is the **fallback** if automation fails.

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P2-S01 ‖ | **Fence traffic**: set ARC routing control for Region A to OFF / Route 53 failover → maintenance page. If the Region A EKS API is reachable: suspend Argo CD auto-sync, then `kubectl --context $EKS_PRIMARY -n $K8S_NS scale deploy -l "$DR_SELECTOR" --replicas=0`; suspend CronJobs | Executor | 3 | No new writes from Region A; record any part that could **not** be done |
| P2-S02 ‖ ⚠ | **Fence old primary** (if control plane reachable): `aws ec2 revoke-security-group-ingress --region $PRIMARY_REGION --group-id $DB_SG_PRIMARY --ip-permissions "$(aws ec2 describe-security-groups --region $PRIMARY_REGION --group-ids $DB_SG_PRIMARY --query 'SecurityGroups[0].IpPermissions')"` (save the rules first: `dr_run sg-before aws ec2 describe-security-groups ...`) | Executor + 2nd eyes | 3 | Old primary unreachable to apps. If skipped → record a **waiver** (input to Phase 5 reconciliation) |
| P2-S03 | Suspend secret rotation for the duration of the event: `aws secretsmanager cancel-rotate-secret --region $PRIMARY_REGION --secret-id $SECRET_ID` (skip if Region A is down — rotation cannot run there either) | Executor | 1 | `RotationEnabled=false` |
| P2-S04 | ✦ *Planned only*: stop writers (P2-S01 done), wait until the primary's `pg_stat_replication.replay_lsn` = `pg_current_wal_lsn()` (see `automation/sql/15-planned-drain.sql`) | DBA | 5 | Lag = 0 bytes → **RPO = 0** |
| P2-S05 | Capture the final replica state **(RPO evidence, do not skip)**: `dr_run replica-final psql "$DR_DSN" -f automation/sql/10-preflight-replica.sql` | DBA | 1 | Last replay LSN + timestamp saved |

> ### ⛳ GATE G2 — Point of no return (IC + DBA)  ·  `aws:approve` in SSM
> Confirm: fencing status (done / waived + why), final LSN captured, estimated data loss accepted at G1.
> `DECISION: G2 GO — ...`

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P2-S06 ⚠ | **Promote** (IRREVERSIBLE). `dr_mark T4` then:<br>`aws rds promote-read-replica --region $DR_REGION --db-instance-identifier $DR_DB --backup-retention-period 7`<br>*Alt-Aurora unplanned:* `aws rds failover-global-cluster --region $DR_REGION --global-cluster-identifier $GLOBAL_CLUSTER --target-db-cluster-identifier $DR_CLUSTER_ARN --allow-data-loss`<br>*Alt-Aurora planned ✦:* `aws rds switchover-global-cluster --region $DR_REGION --global-cluster-identifier $GLOBAL_CLUSTER --target-db-cluster-identifier $DR_CLUSTER_ARN` | Executor + 2nd eyes | 1 | API returns 200; CloudTrail event recorded |
| P2-S07 | **Wait for promotion to complete**: `./automation/scripts/dr-verify.sh wait-promoted`. ⚠ Do **not** rely on `aws rds wait db-instance-available` alone: the instance can still report `available` for a short time *before* it enters `modifying`. Wait until **all** of these are true: `ReadReplicaSourceDBInstanceIdentifier` is empty, status is `available`, `pg_is_in_recovery() = false`. `dr_mark T5` | Executor | 5–15 | Write probe succeeds |
| P2-S08 | **Switch the stable DNS name** (skip for Aurora with the global writer endpoint):<br>`aws route53 change-resource-record-sets --hosted-zone-id $HOSTED_ZONE_ID --change-batch file://<(./automation/scripts/r53-cname-batch.sh "$DB_CNAME" "$(aws rds describe-db-instances --region $DR_REGION --db-instance-identifier $DR_DB --query 'DBInstances[0].Endpoint.Address' --output text)")`<br>then `aws route53 wait resource-record-sets-changed --id <ChangeId>`. `dr_mark T6` | Executor | 2 | Change status `INSYNC`; `dig +short $DB_CNAME` from a DR pod returns the new endpoint |
| P2-S09 ‖ | Send **[Failover Initiated]** comms (all audiences per matrix) | Comms | 5 | Logged |

---

## PHASE 3 — Secret sync & compute recovery (EKS)  (budget: 10 min)

> With the recommended pattern (stable CNAME in the secret), **the secret does not change**. The goal of this phase is to
> make sure every pod has a valid secret **and** a fresh connection pool pointing at the new primary.

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P3-S01 | Verify the secret in the DR cluster is current: `kubectl --context $EKS_DR -n $K8S_NS annotate externalsecret db-creds force-sync=$(date +%s) --overwrite` then `kubectl ... get externalsecret db-creds -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'` | Executor | 1 | `True`, and `refreshTime` is recent |
| P3-S02 | **Legacy only** (the secret holds the instance endpoint). Replica secrets are **read-only**. If Region A is down, first promote the replica secret to standalone: `aws secretsmanager stop-replication-to-replica --region $DR_REGION --secret-id $SECRET_ID`, then update the host: `./automation/scripts/dr-secret-set-host.sh` (`put-secret-value` with `host` replaced). Reloader then rolls the pods. **Backlog: remove this step by moving to the stable CNAME.** | Executor | 3 | New `VersionId`; ESO Ready; Reloader rollout events |
| P3-S03 ‖ | **Scale up** DR workloads to production capacity (can start during Phase 2): `./automation/scripts/dr-eks-rollout.sh scale` (reads target replicas from the `dr.example.com/prod-replicas` annotation) | Executor | 3 | Desired = target; HPA min raised; Cluster Autoscaler/Karpenter adding nodes |
| P3-S04 | **Restart in dependency order** (pools → APIs → workers): `./automation/scripts/dr-eks-rollout.sh restart` (`kubectl rollout restart` per tier + `rollout status --timeout=300s`). `dr_mark T7` | Executor | 5 | All rollouts `successfully rolled out` |
| P3-S05 | Verify connections land on the new primary: `psql "$DR_DSN" -c "select application_name, client_addr, count(*) from pg_stat_activity where datname='$DB_NAME' group by 1,2"`; app logs show no `read-only transaction` / `could not connect` errors after T7 | DBA + App | 2 | Expected app connection counts; error rate ≈ 0 |

---

## PHASE 4 — Post-failover verification & stabilisation  (budget: 15 min to T9, then ongoing)

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P4-S01 | DB integrity checks: `dr_run db-post psql "$DR_DSN" -f automation/sql/20-postfailover-verify.sql` (write probe, read-only flag, invalid indexes, leftover slots, key-table sanity). Record the RPO inputs: `dr_mark RPO_LAST_REPLICATED "value=<last_replicated_heartbeat>"` and `dr_mark RPO_LAST_PRIMARY_COMMIT "value=<last ts logged by heartbeat writer>"` | DBA | 3 | All checks `OK`; RPO markers recorded |
| P4-S02 | App deep health: `./automation/scripts/dr-verify.sh app` (readiness endpoints of critical services, via internal ingress in Region B) | App owner | 2 | All 200 |
| P4-S03 | Smoke / synthetic **business** transactions against the Region B ingress (login, read, create order/plan, background job processed) | App owner | 5 | All pass |

> ### ⛳ GATE G3 — Open traffic (IC + App owner)
> `DECISION: G3 GO` → set the ARC routing control for Region B to ON (or switch the Route 53 failover record) · `dr_mark T8`

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P4-S04 | Watch the public synthetic until **3 consecutive greens**, and the error rate/latency is within SLO for 15 min. `dr_mark T9` at the first of the 3 greens | App owner | 15 | `T9` recorded → **Business RTO = T9 − T0** |
| P4-S05 | **Restore resilience in Region B** (‖ may run after G4): `aws rds modify-db-instance --region $DR_REGION --db-instance-identifier $DR_DB --multi-az --apply-immediately`; confirm backups on (retention 7+); deploy/enable rotation Lambda in Region B and re-enable rotation; CloudWatch alarms/dashboards for the new primary; enable cross-region automated-backup replication *to a healthy region*; Performance Insights | DBA + Executor | — | The DB is HA and backed up again. **Note: you have NO cross-region DR until Phase 5 or a new replica exists** |
| P4-S06 | GitOps alignment: commit the DR state (replica counts, routing, CronJobs enabled in Region B) to Git so Argo CD/Flux does not revert it; re-enable auto-sync | Executor | 5 | Argo CD `Synced/Healthy` in Region B |

> ### ⛳ GATE G4 — Declare service restored (IC) · `dr_mark T10`
> Send **[Services Restored]** comms. Keep the incident open in "monitoring" for ≥ 2 h (PROD).

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P4-S07 | Collect evidence & compute KPIs: `./automation/scripts/dr-collect-evidence.sh && python3 automation/scripts/dr-rto-rpo-calc.py evidence/$DR_ID/timeline.jsonl` | Scribe | 10 | Manifest uploaded to `s3://$EVIDENCE_BUCKET/...`; hash posted in channel |

---

## PHASE 5 — Failback & stabilisation  (separate planned change; Gate G5)

**Never fail back in the same incident.** Region B is now production. Failback is a *planned switchover*, done in
a maintenance window after Region A has been healthy for ≥ 24 h.

| ID | Step | Owner | Expected / verify |
|---|---|---|---|
| P5-S01 | **Preserve the old primary**: when Region A returns, keep it fenced (SG), then `aws rds create-db-snapshot --region $PRIMARY_REGION --db-instance-identifier $PRIMARY_DB --db-snapshot-identifier ${PRIMARY_DB}-pre-failback-$(date -u +%Y%m%d)`. Do **not** delete it | DBA | Snapshot `available` |
| P5-S02 | **Data reconciliation** (if RPO > 0 or fencing was waived): start the old primary in isolation (or restore its snapshot); identify transactions after the final replayed LSN/heartbeat (`automation/sql/30-reconciliation-hints.sql`); Business decides re-apply / discard; document it | DBA + App + Business | Signed reconciliation report |
| P5-S03 | **Re-establish replication Region B → A**: `aws rds create-db-instance-read-replica --region $PRIMARY_REGION --db-instance-identifier ${PRIMARY_DB}-r2 --source-db-instance-identifier arn:aws:rds:${DR_REGION}:${ACCOUNT_ID}:db:${DR_DB} --source-region $DR_REGION --kms-key-id <regionA-key-or-mrk> --db-subnet-group-name <regionA-subnets> --vpc-security-group-ids <regionA-sg> --db-parameter-group-name <pg> --multi-az` | DBA | Replica `available`, `ReplicaLag` ≈ 0 for 24 h |
| | *Alt-Aurora*: after the region recovers, Aurora attempts to re-add the old primary as a secondary (check the global cluster membership). Verify the snapshot Aurora takes of the old primary for lost-write recovery, then use `switchover-global-cluster` back | DBA | Secondary in sync |
| P5-S04 | Gate **G5** (CAB / Service Owner): maintenance window approved, planned-drill comms sent ([`05-planned-drill-notices.md`](../templates/communications/05-planned-drill-notices.md)) | IC | Approved change |
| P5-S05 | Execute **this runbook in planned mode ✦** with Region A/B roles swapped (`source env/prod-failback.env`): drain writes → lag 0 → promote `${PRIMARY_DB}-r2` → CNAME → EKS Region A scale/restart → verify → traffic | Executor | RPO = 0, RTO within the maintenance window |
| P5-S06 | **Restore the DR posture**: create a new cross-region replica A → B (the original topology); re-run pre-flight. Only then is the event fully closed | DBA | Pre-flight PASS in steady state |
| P5-S07 | Decommission superseded instances after the retention period (snapshots kept per policy); rename identifiers if needed (`modify-db-instance --new-db-instance-identifier`), since the stable DNS makes identifiers irrelevant to apps | DBA | Change record |
| P5-S08 | PIR within 5 business days ([template](../templates/reports/post-incident-review.md)); runbook updates merged; **[Post-Mortem / RCA Ready]** comms | IC | PIR published |

---

## 6. Abort / rollback points

| Point | Reversible? | How to back out |
|---|---|---|
| Before P2-S06 (promotion) | **Yes** | Restore SG rules from `sg-before` evidence, ARC control Region A ON, scale Region A back, re-enable rotation |
| After P2-S06 | **No** | The replica is now standalone. The only path back is Phase 5 (rebuild replication, planned switchover) |
| P2-S08 DNS | Yes | UPSERT the previous CNAME target (from `route53-record-before.json`) — **only** if promotion was not done |
| P3 restarts | Yes | `kubectl rollout undo` (rarely needed; restarts are idempotent) |

## 7. Exit criteria
- [ ] Business synthetic green ≥ 15 min, error rate and latency within SLO
- [ ] Region B DB Multi-AZ, backups on, alarms active
- [ ] GitOps in sync with the DR state
- [ ] Evidence bundle uploaded and manifest hash posted
- [ ] RTO/RPO computed and posted
- [ ] Customer/leadership "Restored" comms sent
- [ ] Failback change (Phase 5) raised, with owner and target date

## 8. Change log
| Version | Date | Change | Trigger (drill/PIR) |
|---|---|---|---|
| 1.0-draft | `{{DATE}}` | Initial framework version | Capstone |
