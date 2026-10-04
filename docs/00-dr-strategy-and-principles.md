# 00 — DR Strategy & Principles

## 1. Scope and definitions

| Term | Definition used in this framework |
|---|---|
| **Disaster** | An event where the in-region HA mechanisms (Multi-AZ, pod rescheduling, node replacement) cannot restore service within RTO. Examples: region-wide impairment, account compromise, or logical data corruption/ransomware. |
| **Failover** | A planned or unplanned move of the write role and traffic to the DR region. |
| **Switchover** | A *planned* failover with zero data loss (replication drained first). Used for drills and failback. |
| **Failback** | Returning to the original primary region after recovery. This is a separate, planned change. |
| **RPO** | The maximum acceptable data loss, measured in time (see [`04`](04-rpo-rto-measurement.md) for the exact formula). |
| **RTO** | The maximum acceptable time from **impact start** to **business service restored** (verified by a synthetic transaction). |
| **MTD** | Maximum Tolerable Downtime. The business limit. RTO must be below MTD with margin. |

**Three failure classes need three different recoveries.** A runbook that only covers class A gives a false sense of safety.

| Class | Example | Right recovery | Wrong recovery |
|---|---|---|---|
| A. Infrastructure loss | Region/AZ impairment, network partition | Promote the cross-region replica or fail over the Aurora global cluster | — |
| B. Logical corruption | Bad migration, `DELETE` without `WHERE`, app bug | PITR to a new instance, then a selective data repair | Failover (the replica already holds the corruption) |
| C. Security event | Ransomware, compromised credentials, malicious deletion | Restore from an **isolated, cross-account, Vault-Locked** AWS Backup copy into a clean account | Failover within the same compromised account |

## 2. Service tiering and targets

`TODO(capstone)`: replace these with targets the business has agreed and signed off.

| Tier | Example | RPO | RTO | DR pattern (AWS) | Drill cadence |
|---|---|---|---|---|---|
| **T0 – Mission critical** | Payments, order capture | ≤ 1 min | ≤ 15–30 min | Aurora Global Database + warm-standby EKS, ARC routing | Quarterly switchover (UAT), semi-annual (PROD) |
| **T1 – Business critical** | Core SaaS app (this capstone) | ≤ 5 min | ≤ 1 h | RDS PG cross-region read replica **or** Aurora Global, warm-standby EKS | Quarterly UAT, annual PROD |
| **T2 – Important** | Reporting, internal tools | ≤ 1 h | ≤ 8 h | Pilot light: cross-region automated-backup replication, EKS from GitOps on demand | Semi-annual |
| **T3 – Deferrable** | Sandboxes | ≤ 24 h | ≤ 72 h | Backup & restore (AWS Backup cross-region copy) | Annual restore test |

> **Rule:** never publish an RTO that has not been *measured* in a drill. Publish the measured p90 across the last
> three drills. Do not publish the design target.

## 3. Environment DR matrix (DEV / UAT / PROD)

| Aspect | DEV | UAT / Staging | PROD |
|---|---|---|---|
| DR posture | None, or backup & restore | **Mirror of PROD DR topology**, so drills here are meaningful | Full tier-defined posture |
| Purpose of DR in this env | Developer testing of automation code | **Rehearsal ground**. Every runbook change is drilled here first | Real recovery and scheduled game days |
| Who can declare | Team lead | SRE on-call | Incident Commander + Service Owner (T0/T1 also need an exec approver) |
| Change control | None | Standard change | Pre-approved **emergency change** referenced by the runbook ID |
| Communications | Team chat only | Chat + email to UAT users / QA / implementation consultants | Full matrix ([`06`](06-communications.md)) |
| Evidence retention | 30 days | 1 year | 7 years (Object Lock *compliance* mode, or as policy requires) |
| Customer notice for drills | No | Notify customers who use UAT (e.g. implementation projects) ≥ 5 business days ahead | Per contract/SLA, typically ≥ 10 business days for a planned switchover |

## 4. Decision authority (who can press the button)

```
                 Detect (alarm / customer report)
                              │
                 ┌────────────▼────────────┐
                 │ On-call SRE triage      │  ≤ 10 min
                 │ Is in-region HA enough? │──Yes──► normal incident process
                 └────────────┬────────────┘
                              │ No / unknown
                 ┌────────────▼────────────┐
                 │ Incident Commander      │  Declares "DR Assessment" (SEV1)
                 │ opens bridge + channel  │  Starts the RTO clock (T1)
                 └────────────┬────────────┘
                              │
            ┌─────────────────▼─────────────────────┐
            │ GO / NO-GO gate (Gate G1)             │
            │ Inputs: AWS Health, ARC, replica lag, │
            │ estimated data loss, ETA from AWS     │
            │ Decision makers: IC + Service Owner   │
            │ (+ exec approver for T0/T1 if data    │
            │ loss > 0 is accepted)                 │
            └───────┬─────────────────────┬─────────┘
                 GO │                     │ NO-GO (wait for in-region recovery,
                    ▼                     ▼  re-evaluate every 15 min)
            Execute RB-DR-RDS-001    Keep "DR Assessment" active
```

**Decision rule of thumb (put the agreed version in the runbook):**

- AWS ETA unknown **or** ETA > (RTO − failover duration measured in drills) → **GO**.
- Expected data loss (replica lag) > RPO → escalate to the exec approver. Accepting data loss is a **business** decision, not an engineering one.
- **Pre-authorise** the decision for T0/T1. If the IC cannot reach the approver within 15 min, the IC can proceed. Record this in the DR policy.

## 5. Core principles (architecture and operations)

1. **Static stability.** The DR region must not need the failed region for anything: control-plane calls, IAM Identity Center, CI/CD, container registry (use ECR cross-region replication), secrets (replica secrets), KMS (multi-Region keys), DNS (Route 53 data plane, or ARC routing controls).
2. **Data-plane over control-plane.** Prefer recovery actions that use data-plane operations (ARC routing control state, Route 53 health-check driven records) over control-plane calls, which can be impaired during regional events.
3. **Pre-provision, don't create.** EKS cluster, node groups (scaled-down), IAM roles, security groups, parameter groups and replica secrets already exist in the DR region. Manage them with IaC and check for drift weekly.
4. **One source of truth for the runbook.** Keep it in Git (versioned and reviewed). Mirror read-only copies to (a) the incident tool and (b) an offline PDF in the DR region's S3 bucket and with each IC.
5. **Automate the boring, gate the irreversible.** Promotion, DNS cut-over and fencing are irreversible or high-blast-radius. Each needs a human approval step, even when everything else is automated.
6. **Least privilege, with break-glass.** A dedicated `DRExecutorRole` in each account (MFA, session-recorded, alerting on assume). Do not use personal admin.
7. **Treat drills as production changes.** They need change tickets, comms, evidence and a PIR. Drills that "don't count" create runbooks that don't work.
