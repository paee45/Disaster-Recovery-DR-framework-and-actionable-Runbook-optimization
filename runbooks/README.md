# Runbook Catalogue — RDS PostgreSQL + EKS

## 1. Scenarios × environments

| Scenario | What happens | DEV (primary only) | UAT (primary + replica) | PROD (Multi-AZ + replica) |
|---|---|---|---|---|
| **S1 — Multi-AZ automatic failover** (post-event) | AWS fails over to the standby on its own. **Endpoint does not change** | n/a | n/a | [RB-PROD-S1](prod/RB-PROD-S1-multiaz-failover-post-event.md) |
| **S2 — Read replica promotion** | Replica becomes the new primary. **New endpoint → secret update** | n/a | [RB-UAT-S2](uat/RB-UAT-S2-replica-promotion.md) | [RB-PROD-S2](prod/RB-PROD-S2-replica-promotion.md) |
| **S3 — Restore from daily snapshot** | New instance from an automated/AWS Backup/manual snapshot. **New endpoint → secret update** | [RB-DEV-S3](dev/RB-DEV-S3-snapshot-restore.md) | [RB-UAT-S3](uat/RB-UAT-S3-snapshot-restore.md) | [RB-PROD-S3](prod/RB-PROD-S3-snapshot-restore.md) |
| **S4 — Point-in-time restore (PITR)** | New instance at a chosen time. **New endpoint → secret update** (or surgical repair, no cutover) | [RB-DEV-S4](dev/RB-DEV-S4-pitr.md) | [RB-UAT-S4](uat/RB-UAT-S4-pitr.md) | [RB-PROD-S4](prod/RB-PROD-S4-pitr.md) |

**Post-event failback / normalisation** (always a separate, planned change):

| After | DEV | UAT | PROD |
|---|---|---|---|
| S1 | n/a | n/a | [RB-PROD-FB-S1](prod/RB-PROD-FB-S1-az-rebalance.md): optional AZ rebalance |
| S2 | n/a | [RB-UAT-FB-S2](uat/RB-UAT-FB-S2-rebuild-replica.md) | [RB-PROD-FB-S2](prod/RB-PROD-FB-S2-rebuild-replica-and-ha.md) |
| S3 / S4 | [RB-DEV-FB-S3S4](dev/RB-DEV-FB-S3S4-post-restore-cleanup.md) | [RB-UAT-FB-S3S4](uat/RB-UAT-FB-S3S4-post-restore-normalisation.md) | [RB-PROD-FB-S3S4](prod/RB-PROD-FB-S3S4-post-restore-normalisation.md) |

**Common procedures** (called from every runbook, so they are written once):

| ID | Procedure |
|---|---|
| [CP-01](common/CP-01-secret-endpoint-cutover.md) | Secret endpoint cutover → External Secrets Operator sync → **Reloader** rollout (+ rollback) |
| [CP-02](common/CP-02-post-recovery-verification.md) | Post-recovery verification (DB, app, old instance drained, jobs) |
| [CP-03](common/CP-03-restored-instance-config-parity.md) | Config parity and hardening of a new/promoted instance (+ IaC adoption, monitoring re-pointing) |
| [CP-04](common/CP-04-fencing-old-instance.md) | Fencing the old instance (split-brain / stray writes) |
| [CP-05](common/CP-05-evidence-and-closure.md) | Evidence, RTO/RPO calculation, closure |
| [CP-06](common/CP-06-post-incident-review.md) | Post-incident review (post-mortem), with scenario-specific questions |

## 2. Which scenario? (decision tree)

```
                         DB problem detected
                                │
            Is AWS already failing over Multi-AZ? (RDS events 'failover started'/'completed',
            status 'rebooting'/'modifying' on PROD primary)
                 │yes (PROD)                             │no
                 ▼                                       ▼
          RB-PROD-S1 (wait ≤ 5 min,         Is the DATA wrong? (bad migration, deleted rows,
          then verify; no secret change)    app bug, ransomware)
                                                 │yes                         │no (instance/AZ/host lost,
                                                 ▼                            │ storage-full, unrecoverable)
                               Is the damage small and well-scoped?           ▼
                                 │yes                │no              Replica exists & healthy & lag ≤ RPO?
                                 ▼                   ▼                   │yes (UAT/PROD)        │no / DEV
                    S4 SURGICAL REPAIR      Within backup retention?     ▼                      ▼
                    (PITR side instance,      │yes          │no      S2 replica promotion   Within retention?
                    copy rows back, no        ▼             ▼                               │yes      │no
                    cutover)               S4 PITR     S3 snapshot                         S4 PITR  S3 snapshot
                                           (cutover)   (AWS Backup / manual /                (latest  (daily)
                                                        cross-account copy)                  restorable)
```

> ⚠ **Never promote the replica for a data problem.** The replica has already applied the bad change.
> ⚠ For a **security event** (compromise or ransomware), the Security IR lead becomes IC. Restore only from a backup
> copy the attacker could not reach (cross-account AWS Backup vault), using rotated credentials.

## 3. Conventions used in every runbook

- **Profile:** `source env/<env>.env` (copy from `env/<env>.env.example`), then `source automation/scripts/dr-lib.sh && dr_init <SCENARIO>`.
- **`TARGET_DB`** = the instance that becomes the primary (the promoted replica, or the restored instance). **`OLD_DB`** = the previous primary.
- **Restored instance naming:** `<primary>-r<YYYYMMDDHHMM>` for snapshot and `<primary>-p<YYYYMMDDHHMM>` for PITR (UTC). This makes them unique, sortable and traceable to the event.
- **Step IDs** `P<phase>-S<nn>`. Gates `G<n>` are table rows, so the [tracker generator](../automation/scripts/runbook-to-tracker.py) picks them up. `‖` = can run in parallel, ⚠ = irreversible.
- **Every step** has an owner, a time budget and an expected result. Timestamps come from `dr_mark` (see [`docs/04`](../docs/04-rpo-rto-measurement.md)).

## 4. Environment governance at a glance

| | DEV | UAT | PROD |
|---|---|---|---|
| Declares / approves | Team lead | SRE on-call + QA lead | IC + Service Owner (+ exec if data loss > RPO) |
| Gate approvals in SSM (`MinRequiredApprovals`) | 1 | 1 | 2 (four-eyes) |
| Change type | None | Standard | Pre-approved emergency change |
| Comms | Team chat | Chat + UAT users/projects email | Full matrix ([docs/06](../docs/06-communications.md)) |
| Targets (example, `TODO(capstone)`) | RTO 8 h / RPO 24 h | RTO 4 h / RPO 1 h | RTO 1 h / RPO 5 min (S2), ≤ 15 min (S4) |
| Evidence retention | 30 days | 1 year | 7 years (Object Lock compliance) |
