# 00 — DR Strategy & Principles

## 1. Scope and definitions

| Term | Definition used in this framework |
|---|---|
| **Disaster / DR event** | Any database event where normal operation cannot continue without a recovery action: instance/AZ loss, unrecoverable storage, data corruption, accidental deletion, security compromise |
| **Recovery scenario** | One of **S1** Multi-AZ automatic failover, **S2** read-replica promotion, **S3** snapshot restore, **S4** point-in-time restore (PITR). See the [runbook catalogue](../runbooks/README.md) |
| **Cutover** | Pointing the applications at the new primary by **updating the endpoint in the Secrets Manager secret**. External Secrets Operator syncs it into Kubernetes and Stakater Reloader rolls the pods. **No DNS change** |
| **Failback / normalisation** | The planned work after recovery that returns to the standard topology (Multi-AZ + replica), config parity, IaC and monitoring. Always a separate change |
| **RPO** | The maximum acceptable data loss, measured in time ([04](04-rpo-rto-measurement.md) gives the formula per scenario) |
| **RTO** | The maximum acceptable time from **impact start (T0)** to **business service restored (T9)**, verified by synthetic business transactions |

## 2. Environment topology & recovery options

| | DEV | UAT | PROD |
|---|---|---|---|
| RDS PostgreSQL topology | **Single primary** | **Primary + read replica**, no Multi-AZ | **Multi-AZ primary + read replica** |
| S1 Multi-AZ auto failover | — | — (an AZ failure = primary down → S2/S4) | ✔ automatic, endpoint unchanged |
| S2 Replica promotion | — | ✔ | ✔ |
| S3 Snapshot restore | ✔ (the only path besides S4) | ✔ | ✔ |
| S4 PITR (full cutover or surgical repair) | ✔ | ✔ | ✔ |
| Example targets (`TODO(capstone)`: agree with the business) | RTO 8 h / RPO 24 h | RTO 4 h / RPO 1 h | RTO 1 h / RPO 5 min (S2), ≤ 15 min (S4), 0 (S1) |
| Purpose in the DR programme | Test the **automation** (scripts, SSM, Reloader) | **Rehearse** every PROD runbook (except S1) | Real recovery + scheduled game days |

### Failure class → scenario

| Failure | Example | Scenario | Why not the others |
|---|---|---|---|
| Primary host/AZ failure | Hardware, AZ power, OS patch failover | **S1** (PROD), **S2** (UAT, or PROD if S1 fails) | — |
| Primary unrecoverable / storage | Storage-full that cannot be fixed fast, both AZs impaired | **S2**, else **S4** latest-restorable | — |
| **Logical corruption** | Bad migration, `DELETE` without `WHERE`, app bug | **S4** (surgical or full) | S1/S2 replicate the damage |
| Accidental deletion of the instance | `delete-db-instance` | **S4** from retained automated backups, else **S3** final snapshot | — |
| **Security / ransomware** | Compromised credentials, malicious drop/encrypt | **S3** from an isolated cross-account AWS Backup copy (Vault Lock) into a clean account; Security IR lead is IC | Same-account backups may be tampered with |
| Need an older state than retention | Audit, a late-discovered corruption | **S3** (manual/AWS Backup snapshot) | PITR window exceeded |

## 3. Decision authority

```
 Detect (alarm / customer report / RDS event)
          │
 On-call triage (≤ 10 min) ── Multi-AZ failover in progress? ──yes──► RB-PROD-S1 (time box 5 min)
          │ no / time box exceeded
 Incident Commander declares SEV, opens channel + bridge  (T1)
          │
 Scenario choice via the decision tree (runbooks/README.md §2) ── DECISION recorded
          │
 Gate G1 (approvers per env, below) — accepts the data-loss estimate
          │
 Execute the env-specific runbook; gates G2 (point of no return), G3 (cutover), G4 (restored)
```

| Env | Declares | G1 approvers | Data loss > RPO accepted by |
|---|---|---|---|
| DEV | Engineer | Team lead | Team lead |
| UAT | SRE on-call | SRE on-call + QA lead | QA lead / project lead |
| PROD | Incident Commander | IC + Service Owner (2 approvals in SSM) | **Exec approver** (business decision) |

**Pre-authorise** the PROD decision: if the approver cannot be reached within 15 min, the IC may proceed. Record this in the DR policy.

## 4. Core principles

1. **Recover the business service, not the database.** Done = a synthetic business transaction passes.
2. **Choose the scenario by the failure class, not by habit.** Never promote a replica for a data problem.
3. **One cutover mechanism everywhere:** secret update → ESO → Reloader. It is the same in DEV, UAT and PROD, so DEV/UAT drills exercise the exact PROD path.
4. **Fence the old instance.** With secret-based cutover, stray writers (unrolled pods, CronJobs, scripts) can keep writing to the old DB.
5. **Restores are never "as-is".** Pass hardening flags explicitly and run the parity check (SGs, parameter group, Multi-AZ, backups, tags, alarms, IaC).
6. **Decide with humans, execute with code.** Irreversible steps have gates with recorded approvers (SSM `aws:approve`).
7. **Every step writes a timestamp, and evidence is a by-product.** RTO/RPO are computed, not reconstructed.
8. **Every recovery has a normalisation runbook.** The incident is not over until the DR posture (Multi-AZ + replica in PROD) is restored.
9. **An untested runbook does not exist.** Each env/scenario pair has a drill cadence ([07](07-testing-and-drill-program.md)).
10. **Every execution improves the runbook.** Deviations become tickets; the runbook version and change log reference the PIR.
