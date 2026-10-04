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
| [CP-07](common/CP-07-troubleshooting.md) | Troubleshooting: env/tooling, RDS, secret/ESO/Reloader/EKS |

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
                    S4 SURGICAL REPAIR      Within 7-day retention?      ▼                      ▼
                    (PITR side instance,      │yes          │no      S2 replica promotion   Within 7 days?
                    copy rows back, no        ▼             ▼                               │yes      │no
                    cutover)               S4 PITR     S3 MANUAL snapshot                  S4 PITR  S3 snapshot
                                           (cutover)   only (if one exists;                 (latest  (daily)
                                                        else unrecoverable, R4)              restorable)
```

> ⚠ **Never promote the replica for a data problem.** The replica has already applied the bad change.
> ⚠ For a **security event** (compromise or ransomware), the Security IR lead becomes IC. Restore with rotated credentials into
> a clean VPC. There is no isolated (cross-account) backup copy today: accepted risk R5 ([docs/09](../docs/09-iso27001-scope.md)).

## 3. Conventions used in every runbook

- **Profile:** `source env/<env>.env` (copy from `env/<env>.env.example`), run `./automation/scripts/dr-env-check.sh <SCENARIO>` (must PASS), then `source automation/scripts/dr-lib.sh && dr_init <SCENARIO>`. Never edit values inside commands.
- **Recorded shell (recommended):** `./automation/scripts/dr-session.sh env/<env>.env <SCENARIO>` does the profile + guard + `dr_init` and records the whole terminal session, command history and every aws/kubectl call into the evidence folder (synced to S3). See [docs/05](../docs/05-evidence-and-audit.md).
- **Strict pinning:** every `aws` command is written `aws --profile $AWS_PROFILE --region $AWS_REGION …` and every `kubectl` command `kubectl --context $EKS_CONTEXT …` (as in the snippets). Without the flags the shell refuses the command (exit 97) — by design, see [docs/12](../docs/12-account-and-cluster-safety.md).
- **CLI, not console:** every action has a copy-paste CLI command or script ([CLI quick reference](../docs/11-aws-cli-quick-reference.md)).
- **Phase timers:** `dr_phase start|end <phase> <budget>`; `dr_summary` shows where the time went.
- **`TARGET_DB`** = the instance that becomes the primary (the promoted replica, or the restored instance). **`OLD_DB`** = the previous primary.
- **Restored instance naming:** `<primary>-r<YYYYMMDDHHMM>` for snapshot and `<primary>-p<YYYYMMDDHHMM>` for PITR (UTC). This makes them unique, sortable and traceable to the event.
- **Step IDs** `P<phase>-S<nn>`. Gates `G<n>` are table rows, so the [tracker generator](../automation/scripts/runbook-to-tracker.py) picks them up. `‖` = can run in parallel, ⚠ = irreversible.
- **Every step** has an owner, a time budget and an expected result. Timestamps come from `dr_mark` (see [`docs/04`](../docs/04-rpo-rto-measurement.md)).

## 4. Environment governance at a glance

| | DEV | UAT | PROD |
|---|---|---|---|
| Declares / approves | Team lead | SRE on-call + QA lead | IC + SRE lead; **CTO** accepts data loss |
| Gate approvals in SSM (`MinRequiredApprovals`) | 1 | 1 | 2 (four-eyes) |
| Change type | None | Standard | Pre-approved emergency change |
| Comms | Team chat | Chat + UAT users/projects email | Full matrix ([docs/06](../docs/06-communications.md)) |
| Targets (all envs) | RTO 30 min (aim) / RPO 24 h | RTO 30 min (aim) / RPO 24 h | RTO 30 min (aim) / RPO 24 h |
| Backups | RDS automated, 7-day retention | same | same |
| DR testing | Not scheduled | Not scheduled | Not scheduled |
| Evidence retention | Per ISMS records policy (`TODO`) | same | same |

## 5. Document control (ISO/IEC 27001:2022 clause 7.5, A.5.37)

| Item | Rule |
|---|---|
| Owner | SRE (`{{SRE_OWNER}}`) |
| Review / approval | Every change by Git pull request: **reviewed by the SRE lead, approved by the CTO**. The merged PR is the approval record |
| Classification | Internal |
| Review cycle | At least every 12 months, and after every DR event, significant architecture change or ISMS audit finding |
| Versioning | `vMAJOR.MINOR` in each runbook header, plus a change-log row that references the PR/PIR |
| Scope & controls | [docs/09 — ISO 27001 scope](../docs/09-iso27001-scope.md) |
