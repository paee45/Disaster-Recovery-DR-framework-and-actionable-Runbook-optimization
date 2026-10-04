# Enterprise DR Framework — AWS RDS PostgreSQL + EKS

Capstone: **Enterprise Disaster Recovery framework and actionable runbook optimization** for RDS PostgreSQL, where
recovery = a new/promoted DB endpoint written into **Secrets Manager**, synced by **External Secrets Operator**, with pods
restarted automatically by **Stakater Reloader** (no DNS change).

> Status: **v0.5**. Includes the corrective action plan for the 2026-08-04 UAT exercise (RTO 39:55 vs 30 min) → [docs/10](docs/10-corrective-action-plan-2026-08-04.md).
> v0.5: baseline-driven restore (`capture` → `plan` → restore → `harden` → `validate`/`validate-pg`), standalone stale-pod tool
> `k8s-secret-consumers.sh`, **strict pinning** (no default profile/context; unpinned calls refused), recorded DR shell
> `dr-session.sh` + `commands.jsonl` audit + continuous evidence sync to S3, pinning lint in CI. See [docs/12](docs/12-account-and-cluster-safety.md).
> Targets: **RPO 24 h** (RDS daily backup, 7-day retention), **RTO 30 min** (aim). No DR drills are scheduled.
> Runbooks are ISMS documents (ISO/IEC 27001:2022), reviewed by the SRE lead and approved by the CTO. Fill in the placeholders (`{{…}}`, `TODO`) and `env/<env>.env`.

## Topology in scope

| Env | RDS PostgreSQL | Recovery scenarios |
|---|---|---|
| **DEV** | Single primary | S3 snapshot restore · S4 PITR |
| **UAT** | Primary + read replica (no Multi-AZ) | S2 replica promotion · S3 · S4 |
| **PROD** | Multi-AZ primary + read replica | S1 Multi-AZ auto failover (post-event) · S2 · S3 · S4 |

Each env/scenario pair has its **own runbook**, plus a separate **failback / normalisation runbook** and a **post-incident review**.
Start at the **[runbook catalogue and decision tree](runbooks/README.md)**.

## Repository map

| Path | What it is |
|---|---|
| [`runbooks/README.md`](runbooks/README.md) | Catalogue: scenario × env matrix, decision tree, conventions |
| `runbooks/prod/` · `runbooks/uat/` · `runbooks/dev/` | **15 runbooks**: S1–S4 per env, plus FB (failback/normalisation) runbooks |
| `runbooks/common/` | Shared procedures: **CP-01 secret cutover + Reloader**, CP-02 verification, CP-03 config parity/IaC, CP-04 fencing, CP-05 evidence, CP-06 post-incident review, CP-07 troubleshooting |
| `env/*.env.example` | Per-environment variables (instance IDs, secrets, EKS context, targets) |
| [`automation/`](automation/) | SSM Automation documents, scripts (cutover, Reloader wait, restore, fence, parity, evidence, KPIs, tracker generator), SQL, K8s manifests |
| [`docs/`](docs/) | 00 strategy · 01 architecture · 02 runbook standards · 03 execution media/tooling · 04 RPO/RTO · 05 evidence/audit · 06 comms · 07 validation (no scheduled drills) · 08 capstone optimization · **09 ISO 27001 scope, control mapping & risk register** · **10 corrective action plan (UAT exercise 2026-08-04)** · 11 AWS CLI quick reference · **12 account & cluster safety (guardrails)** |
| [`tests/`](tests/) | **Local test bed** (k3s + LocalStack + moto + Postgres + ESO + Reloader + 3 sample apps; 100 end-to-end tests, [last run](tests/local/last-run-report.md)) and the **real-AWS sandbox test** |
| [`templates/`](templates/) | Comms (chat, leadership, vendor, customer/status page, planned drills), execution tracker, evidence manifest, drill report, PIR, runbook template |

## Ten rules this framework is built on

1. **Recover the business service, not the database.** Done = a synthetic business transaction passes (T9).
2. **Choose the scenario by the failure class.** Never promote a replica for a data problem; use PITR.
3. **One cutover mechanism everywhere:** secret update → ESO force-sync → Reloader rollouts (verified, with a manual fallback).
4. **Fence the old instance.** Pods that have not restarted, CronJobs and scripts can still write to it.
5. **Restores are never "as-is".** Pass explicit hardening flags, then run the parity check (SG, parameter group, Multi-AZ, backups, tags, alarms, IaC).
6. **Check the password trap.** A restored DB has passwords as of the restore point, so pre-check the login before the cutover.
7. **Decide with humans, execute with code.** Gates are SSM `aws:approve` steps (PROD four-eyes).
8. **Every step writes a timestamp, and evidence is a by-product.** RTO/RPO are computed from `timeline.jsonl`.
9. **The incident ends when the DR posture is back** (Multi-AZ + replica), not when the app is up.
10. **Runbooks are controlled ISMS documents.** Reviewed by the SRE lead, approved by the CTO, re-reviewed yearly and after every event; every deviation becomes a ticket.

## Quick start
```bash
cp env/uat.env.example env/uat.env && $EDITOR env/uat.env
source env/uat.env && source automation/scripts/dr-lib.sh && dr_init S2
./automation/scripts/dr-preflight.sh replica                 # read-only checks
python3 automation/scripts/runbook-to-tracker.py runbooks/uat/RB-UAT-S2-replica-promotion.md --expand -o tracker.csv
```

## To-do / improvements (tracked, not yet done)
| # | Item | Why | Now |
|---|---|---|---|
| 1 | **Adopt ESO for the DB secret** (`SECRET_MODE=eso`): Secrets Manager as the source of truth, ExternalSecret template mapping `host` → `POSTGRES_DB_HOST1`, `POSTGRES_DB_HOST2` | One audited source (CloudTrail), rotation support, no secret values in cluster manifests | `SECRET_MODE=k8s`: direct patch of the K8s Secret + ledger ConfigMap (`k8s-secret-endpoint.sh`) |
| 2 | ESO mode: failback by change ID (custom Secrets Manager staging labels `DR-<id>` per version, or ledger as in k8s mode) | Today ESO mode only steps back one version (`AWSPREVIOUS`) | Use k8s mode, or `apply` with `TARGET_DB=<original>` |
| 3 | Reloader alerts to the incident channel (Slack/Teams webhook Secret `reloader-alerts`) in UAT/PROD | Reloader has no UI | Example in `automation/k8s/reloader-values.yaml`; tested locally with a webhook sink |
| 4 | Reloader metrics scraped (`serviceMonitor`) + `DRReloaderReloadFailed` alert routed | Detect a failed reload without looking | Rules in `automation/k8s/prometheus-rules.yaml` |
| 5 | Annotate every DB consumer for Reloader (app-e style workloads) | Unannotated consumers keep the old endpoint | `k8s-secret-consumers.sh check` / `restart-stale` finds and restarts them |
