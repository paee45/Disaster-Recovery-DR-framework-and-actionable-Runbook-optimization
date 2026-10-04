# RB-PROD-S1 — Multi-AZ Automatic Failover: Post-Event Runbook (PROD)

| Field | Value |
|---|---|
| Version / owner / approver | v1.0-draft / `{{SRE_OWNER}}` / `{{SERVICE_OWNER}}` |
| Topology | `app-pg-prod` Multi-AZ (primary + synchronous standby) + read replica `app-pg-prod-replica` |
| What AWS does | Detects the primary failure → promotes the standby → **flips the same endpoint DNS** to the new host (typically 60–120 s) → builds a new standby in the background |
| Secret change | **None.** The endpoint is unchanged, so Reloader is **not** triggered |
| Targets | RPO **0** (synchronous). RTO ≤ 5 min (AWS) + app reconnect |
| Last drill | `{{date}}` (drilled with `reboot-db-instance --force-failover` in a maintenance window, see [docs/07](../../docs/07-testing-and-drill-program.md)) |

**Use when:** an RDS event shows a Multi-AZ failover started/completed on `$PRIMARY_DB`, or the instance is `rebooting`/`modifying` with failover.
**Do not:** start a replica promotion (S2) or a restore while an automatic failover is in progress. **Wait up to 5 min**
(the time box), then re-assess with the [decision tree](../README.md#2-which-scenario-decision-tree).

```bash
source env/prod.env && source automation/scripts/dr-lib.sh && dr_init S1
dr_set_target "$PRIMARY_DB"           # the same instance; the endpoint is unchanged
```

## Phase 1 — Confirm the event (budget 5 min)

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P1-S01 | Open the incident (SEV2 by default; SEV1 if impact > 5 min). Post [Investigating] in the internal chat. `dr_mark T1` | On-call SRE | 2 | Channel open |
| P1-S02 | RDS events: `dr_run rds-events aws rds describe-events --source-type db-instance --source-identifier $PRIMARY_DB --duration 120`. Look for the Multi-AZ failover *started* / *completed* events and their **reason** message | SRE | 1 | Failover started at `T_fo_start`, completed at `T_fo_end`. `dr_mark T4 --at <started>` / `dr_mark T5 --at <completed>` |
| P1-S03 | Instance state: `aws rds describe-db-instances --db-instance-identifier $PRIMARY_DB --query 'DBInstances[0].{st:DBInstanceStatus,az:AvailabilityZone,az2:SecondaryAvailabilityZone,maz:MultiAZ}'` (compare the AZ with the CMDB/last evidence) | SRE | 1 | `available`, AZ changed, `MultiAZ=true` |
| P1-S04 | If still not `available` after **5 min** since `T_fo_start` → escalate: AWS Support case (Business-critical) + switch to the decision tree (S2 if lag OK). `DECISION:` recorded | IC | — | Decision recorded |

## Phase 2 — Application recovery & verification (budget 10 min)

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P2-S01 | Check app errors since `T_fo_end` (5xx, `could not connect`, `the database system is shutting down`, `read-only transaction`). Most drivers reconnect automatically | App owner | 3 | Error rate back to baseline |
| P2-S02 | **If errors persist > 3 min after `T_fo_end`:** stale DNS/connection pools (JVM DNS cache, pool without validation). Force a fresh pool: `./automation/scripts/dr-eks-rollout.sh restart` (ordered rolling restart; no secret change, so Reloader does not do it). Record it as a **PIR action** (fix TTL/pool settings) | Executor | 5 | All consumers rolled; errors gone |
| P2-S03 | **Read replica health**: `aws rds describe-db-instances --db-instance-identifier $REPLICA_DB --query 'DBInstances[0].StatusInfos'` + CloudWatch `ReplicaLag` | DBA | 2 | `replicating`, lag back to normal (the replica reconnects to the new primary host by itself) |
| P2-S04 | **Standby rebuilt**: `SecondaryAvailabilityZone` populated and status `available`. Until then **PROD has no HA**, so freeze risky changes | DBA | async | Standby present |
| P2-S05 | Run [CP-02](../common/CP-02-post-recovery-verification.md) steps S01, S03 (no OLD_DB), S04–S07 | App owner + DBA | 15 | All pass. `dr_mark T9` at the first of 3 green synthetics |
| P2-S06 | **AZ affinity check**: are the app pods now mostly in a different AZ from the DB? Check p95 DB latency vs baseline. If degraded beyond SLO → plan [RB-PROD-FB-S1](RB-PROD-FB-S1-az-rebalance.md) | SRE | 3 | Decision: rebalance yes/no |
| P2-G4 ⛳ | Declare restored (IC). [Services Restored] comms, **only to the audiences already informed** (if impact < 5 min and no customer report, internal only, per [docs/06](../../docs/06-communications.md)). `dr_mark T10` | IC | 1 | Recorded |

## Phase 3 — Post-event (same day)

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P3-S01 | Root-cause inputs: the RDS event reason, AWS Health events for the account/AZ, CloudTrail (`RebootDBInstance`, `ModifyDBInstance`: was the failover human/maintenance-triggered?), `PendingModifiedValues`/maintenance actions (`aws rds describe-pending-maintenance-actions`) | SRE | 15 | Cause classified: infra / maintenance / human |
| P3-S02 | [CP-05](../common/CP-05-evidence-and-closure.md) evidence (RPO = 0; RTO = `T9 − T0`) | Scribe | 10 | Uploaded |
| P3-S03 | [CP-06](../common/CP-06-post-incident-review.md) PIR (S1 questions). Mandatory if the app impact exceeded the AWS failover time by > 2 min | IC | — | Booked |

**Failback:** there is no failback for Multi-AZ. The standby is rebuilt automatically. Only an *optional* AZ rebalance → [RB-PROD-FB-S1](RB-PROD-FB-S1-az-rebalance.md).

## Change log
| Version | Date | Change | Trigger |
|---|---|---|---|
| 1.0-draft | `{{date}}` | Initial | Capstone |
