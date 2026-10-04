# 09 — ISO/IEC 27001:2022 Scope, Control Mapping & DR Risk Register

| Document control | |
|---|---|
| Document | ISMS — Database Disaster Recovery (RDS PostgreSQL + EKS) |
| Version | v0.1-draft |
| Owner | SRE (`{{SRE_OWNER}}`) |
| Reviewed by | SRE lead (`{{name}}`) |
| Approved by | CTO (`{{name}}`) |
| Classification | Internal |
| Review cycle | At least every 12 months; also after a DR event, a significant architecture change or an audit finding |
| Approval record | Merged pull request in this repository (reviewer + approver recorded by Git hosting) |

## 1. Scope statement (clause 4.3)

> The ISMS scope for database disaster recovery covers the **processes, documented procedures, people and technology**
> used to detect, decide on, recover from and learn from the loss or corruption of the **`{{SERVICE}}` Amazon RDS for
> PostgreSQL databases** and to reconnect their **Amazon EKS-hosted consumers**, in AWS account(s) `{{ACCOUNT_IDS}}`,
> region **eu-west-1**, for the **DEV, UAT and PROD** environments. It is operated by the SRE team under the authority of the CTO.

### In scope

| Area | Items |
|---|---|
| Data stores | RDS PostgreSQL: `app-pg-dev` (single), `app-pg-uat` + replica, `app-pg-prod` (Multi-AZ) + replica |
| Backup & recovery | RDS automated backups (PITR) + daily automated snapshots, **7-day retention**; recovery scenarios S1–S4 + FB runbooks |
| Credentials & cutover | AWS Secrets Manager DB secrets (`<env>/app/db`, `<env>/app/db-ro`, master secret), External Secrets Operator, Stakater Reloader |
| Compute consumers | EKS workloads that consume the DB secrets (Deployments, StatefulSets, CronJobs, Jobs) |
| Procedures | `runbooks/` (15 runbooks + CP-01…CP-06), `docs/`, comms templates, evidence process |
| Automation | `automation/` scripts and SSM Automation documents |
| People / roles | IC, Executor, DBA, Scribe, Comms lead, SRE lead (reviewer), CTO (approver, risk owner) |
| Records | Timeline, evidence bundles, PIRs, approvals (PRs, SSM `aws:approve`) |

### Out of scope (with justification)

| Item | Justification / where it is handled |
|---|---|
| **Regional AWS outage** recovery | No cross-region replica or backup copy today; **accepted risk R1** |
| Recovery from an **isolated / cross-account backup** | Not implemented; **accepted risk R5** |
| AWS infrastructure below the RDS/EKS service boundary | AWS responsibility under the shared responsibility model (A.5.23); supplier assurance via AWS SOC/ISO reports |
| Application code, non-RDS data stores (S3, caches, queues) | Separate continuity procedures (`TODO` if any) |
| Business continuity of people/offices, crisis management | Company BCP |
| Customer-side systems and integrations | Partners' responsibility; notification covered by comms templates |

### Interfaces & dependencies
AWS (RDS, Secrets Manager, EKS, CloudTrail, CloudWatch, SSM, S3), the incident tool / chat (Slack or Teams), Git hosting
(document control), on-call paging, and AWS Support (supplier, A.5.21–A.5.23).

## 2. ISMS clause mapping

| Clause | How this framework addresses it |
|---|---|
| 4.3 Scope | §1 of this document |
| 5.3 Roles, responsibilities, authorities | Runbook roles ([02 §4](02-runbook-standards.md)), decision authority ([00 §3](00-dr-strategy-and-principles.md)); CTO = approver and risk owner |
| 6.1.2 / 6.1.3 Risk assessment & treatment | DR risk register (§5) → feeds the ISMS risk register and the Statement of Applicability |
| 6.2 Objectives | **RPO 24 h, RTO 30 min** (all envs); measured per event (`dr-rto-rpo-calc.py`) |
| 7.2 / 7.3 Competence & awareness | Two people per role; yearly read-through + DEV dry-run practice (TICKET-108); attendance recorded |
| 7.5 Documented information | Git-based document control: version, PR review (SRE lead), approval (CTO), change log |
| 8.1 Operational planning & control | Env × scenario runbooks, gates, change types (emergency/standard) |
| 9.1 Monitoring & measurement | KPIs per event: business RTO, RPO, decision time, cutover time, deviations |
| 9.2 Internal audit | Evidence bundles (manifest + SHA-256) can be sampled by internal audit |
| 10.2 Nonconformity & corrective action | PIR/exercise action items with owner/due date + effectiveness review; first CAPA: [10](10-corrective-action-plan-2026-08-04.md) |

## 3. Annex A control mapping (input to the Statement of Applicability)

Status: ✅ implemented by this framework · 🟡 partially (action open) · ❌ gap (risk accepted).

| Control | Requirement (summary) | Implementation | Evidence | Status |
|---|---|---|---|---|
| **A.5.24** Incident mgmt planning & preparation | Roles, procedures | Roles, runbooks, comms templates | `runbooks/`, `docs/02`, `docs/06` | ✅ |
| **A.5.25** Assessment & decision on events | Classify events | Decision tree, failure-class table, gate G1 | `runbooks/README.md §2`, `DECISION:` log | ✅ |
| **A.5.26** Response to incidents | Documented response | S1–S4 runbooks, CP-01…CP-04 | Timeline, SSM executions | ✅ |
| **A.5.27** Learning from incidents | Use knowledge gained | CP-06 PIR with scenario questions; runbook change log | PIR, PRs | ✅ |
| **A.5.28** Collection of evidence | Identify, collect, preserve | CP-05, `dr-collect-evidence.sh`, SHA-256 manifest, Object Lock | Evidence bucket | 🟡 bucket + Object Lock to be created |
| **A.5.29** Security during disruption | Maintain security during disruption | Fencing (CP-04), passwords never in evidence/logs, rotation handled, IAM-scoped executor role, four-eyes gates in PROD | Fence records, approvals | ✅ |
| **A.5.30** ICT readiness for BC | Plan, implement, maintain **and test** ICT continuity based on objectives | RPO/RTO defined, runbooks, automation. One UAT S3 exercise (2026-08-04): **RTO not met** → corrective actions | Exercise report, [CAPA](10-corrective-action-plan-2026-08-04.md) | 🟡 CAPA open; no regular testing (R2) |
| **A.5.37** Documented operating procedures | Procedures documented and available | Runbooks in Git; offline/PDF copy recommended | Repo, PR history | ✅ |
| **A.5.23** Use of cloud services | Manage cloud-service security | Shared responsibility documented; AWS Support case template | `03-supplier-vendor.md` | ✅ |
| **A.5.34** Privacy & PII protection | Protect PII | Data-loss events: CTO decides on DPO/regulatory notification | Comms log | ✅ |
| **A.6.3** Awareness & training | Personnel aware | Read-through recommended; no drills | Attendance record (`TODO`) | 🟡 |
| **A.8.2** Privileged access rights | Restrict and control | `DRExecutorRole`, master secret only used by fencing/password-fix scripts, SSM approvals | IAM policy, CloudTrail | 🟡 role/RBAC to be created ([automation/README](../automation/README.md)) |
| **A.8.9** Configuration management | Secure configurations maintained | CP-03 parity diff, hardened restore flags, IaC adoption | Parity output, Terraform plan | ✅ |
| **A.8.10** Information deletion | Delete when no longer required | Decommission steps with final snapshot + retention (FB runbooks) | CloudTrail `DeleteDBInstance` | ✅ |
| **A.8.13** Information backup | Backups maintained **and tested** | RDS automated backups + daily snapshot, 7-day retention; snapshot restore tested in UAT 2026-08-04 (RPO met) | Exercise report, alarms | 🟡 no regular restore test (R2), retention 7 d (R4), same account (R5) |
| **A.8.14** Redundancy | Sufficient redundancy | PROD Multi-AZ + same-region replica; UAT replica | RDS config | 🟡 no regional redundancy (R1) |
| **A.8.15** Logging | Logs produced and protected | CloudTrail, RDS events, `timeline.jsonl` in evidence | Evidence bundle | ✅ (verify CloudTrail is enabled in all accounts) |
| **A.8.16** Monitoring activities | Monitor for anomalous behaviour | Replica lag, heartbeat, snapshot age, ESO/Reloader alerts | Alert rules | 🟡 alerts to be deployed |
| **A.8.24** Use of cryptography | Encryption | Encrypted RDS storage/snapshots (KMS), TLS `verify-full` in scripts | RDS `StorageEncrypted`, parity check | ✅ (verify) |
| **A.8.32** Change management | Changes controlled | Pre-approved emergency change for recovery; FB runbooks as standard changes; runbook changes via PR | Change records, PRs | ✅ |

## 4. Objectives and targets (6.2)

| Objective | Target | Measured by | Current confidence |
|---|---|---|---|
| RPO | **24 h** (all envs) | KPI report per event | High: daily snapshot; PITR is usually minutes |
| RTO | **30 min** (all envs, aim) | `T9 − T0` per event | S1 high · S2 medium · **S3 measured 39:55 (UAT, not met)** · S4 low (R3) |
| Runbook currency | Reviewed ≤ 12 months | PR history | — |
| Learning | 100 % of events have a PIR and actions | PIR register | — |

## 5. DR risk register (input to 6.1.3 risk treatment)

Likelihood (L) / impact (I): 1 = low … 5 = high. `TODO`: align with the ISMS risk methodology. Risk owner for all: **CTO**.

| ID | Risk | L | I | Treatment | Decision | Review date |
|---|---|---|---|---|---|---|
| **R1** | **Regional AWS outage**: primary, replica and backups are all in eu-west-1 → no recovery within RPO/RTO until the region returns | 1 | 5 | Option: cross-region automated-backup replication (low cost) or a cross-region replica | **Accept for now** | `{{date + 12 m}}` |
| **R2** | **No regular DR testing** (one UAT S3 exercise on 2026-08-04, none scheduled) → other scenarios and PROD unproven; A.5.30/A.8.13 expect testing | 3 | 4 | Desk review, CI checks, read-only pre-flight, DRY_RUN, learning from events ([07](07-testing-and-drill-program.md)) | **Accept** (with the mitigations listed) | `{{date + 6 m}}` |
| **R3** | **RTO 30 min not met for S3** — measured 39:55 in UAT (0.6 GB) due to manual steps/scripts/runbook clarity; PROD (larger) likely longer | 4 | 3 | Corrective actions TICKET-101…108 ([10](10-corrective-action-plan-2026-08-04.md)); effectiveness review | **Treat** (CAPA) | `{{date + 6 m}}` |
| **R4** | **7-day retention**: corruption discovered after 7 days is unrecoverable (no older snapshots) | 2 | 4 | Option: monthly manual snapshot or AWS Backup monthly plan | **Accept for now** | `{{date + 12 m}}` |
| **R5** | **No isolated backup copy**: account compromise/ransomware could delete instances *and* backups | 2 | 5 | Option: AWS Backup copy to a separate account with Vault Lock; strict IAM, deletion protection, CloudTrail alerts on `Delete*` | **Accept for now** | `{{date + 12 m}}` |
| **R6** | **S1 behaviour not rehearsable in UAT** (no Multi-AZ) → app reconnect issues found only in PROD | 3 | 2 | App settings (DNS TTL, pool lifetime, readiness/liveness); S1 runbook fallback restart | **Accept** | `{{date + 12 m}}` |
| **R7** | **Cutover depends on ESO + Reloader**: if either is down, pods keep the old endpoint | 2 | 3 | HA Reloader, alerts, verified rollout with automatic manual-restart fallback, inventory gate | **Mitigated** | `{{date + 12 m}}` |
| **R8** | **Key-person dependency**: few people know the procedures, and there are no drills | 3 | 3 | Two people per role, yearly read-through, runbooks executable as written | **Mitigate** (read-through) | `{{date + 12 m}}` |

**Risk acceptance (CTO):** name `{{}}` · date `{{}}` · signature/PR `{{link}}`.

## 6. Records produced (7.5.3 control of records)

| Record | Location | Retention |
|---|---|---|
| Runbook versions + approvals | Git history / PRs | Life of the repository |
| Incident timeline, evidence bundle, KPI report | `s3://<evidence-bucket>/<env>/<yyyy>/<DR_ID>/` (Object Lock) | Per ISMS records policy (`TODO`) |
| PIRs and action items | PIR folder in the evidence bundle + ticket system | Per ISMS records policy |
| Risk acceptance | This document (PR) + ISMS risk register | Until superseded |
| Comms sent | `comms/sent-messages.md` in the evidence bundle | Per ISMS records policy |
