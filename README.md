# Enterprise DR Framework — RDS/Aurora PostgreSQL + EKS

Capstone: **Enterprise Disaster Recovery framework and actionable runbook optimization**, focused on the
RDS PostgreSQL regional failover runbook, with automated secret/endpoint discovery and EKS workload restart.

> Status: **v0.1 baseline**. This is a best-practice reference implementation. The capstone-specific details
> (real identifiers, targets, org names) still need to be filled in. Search the repo for `{{` placeholders and `TODO(capstone)`.

---

## How this repo is organised

| Path | What it is | Who uses it |
|---|---|---|
| [`docs/00-dr-strategy-and-principles.md`](docs/00-dr-strategy-and-principles.md) | Tiering, RPO/RTO targets, DR patterns per environment, decision authority, core principles | Leadership, architects |
| [`docs/01-reference-architecture.md`](docs/01-reference-architecture.md) | Target DR architecture (RDS/Aurora, Route 53, Secrets Manager, ESO, Reloader, EKS) | Architects, SRE |
| [`docs/02-runbook-standards.md`](docs/02-runbook-standards.md) | How a runbook must be written: anatomy, step format, gates, roles, versioning | Runbook authors |
| [`docs/03-execution-media-and-tooling.md`](docs/03-execution-media-and-tooling.md) | Sheet vs UI tool vs runbook-as-code. Scored comparison and the recommended hybrid | SRE leads, tooling owners |
| [`docs/04-rpo-rto-measurement.md`](docs/04-rpo-rto-measurement.md) | Exact definitions, timestamps, metrics and queries for RPO/RTO | SRE, auditors |
| [`docs/05-evidence-and-audit.md`](docs/05-evidence-and-audit.md) | Automated evidence capture, WORM storage, SOC 2 / ISO 27001 control mapping | SRE, GRC |
| [`docs/06-communications.md`](docs/06-communications.md) | Communication matrix (who, when, what channel, who approves) for DEV/UAT/PROD | Incident Commander, Comms lead |
| [`docs/07-testing-and-drill-program.md`](docs/07-testing-and-drill-program.md) | Drill types, cadence, game days, AWS FIS, scoring, maturity model | SRE leads |
| [`docs/08-capstone-runbook-optimization.md`](docs/08-capstone-runbook-optimization.md) | Gap analysis approach, before/after model, optimization backlog and KPIs | Capstone owner |
| [`runbooks/RB-DR-RDS-001-postgres-regional-failover.md`](runbooks/RB-DR-RDS-001-postgres-regional-failover.md) | **The runbook**: 5 phases, gated, with commands | On-call / DR executors |
| [`automation/`](automation/) | SSM Automation document, Bash/Python scripts, SQL, Kubernetes manifests | Executed by the runbook |
| [`templates/`](templates/) | Comms templates (chat/email/status page), evidence manifest, execution tracker, drill report, PIR | Everyone |

## The ten rules this framework is built on

1. **Recover the business service, not the database.** "Done" means a synthetic business transaction passes. A DB in `available` state is not enough.
2. **Decide with humans, execute with code.** People make the call to fail over. Automation runs the steps. Every irreversible step sits behind an explicit gate.
3. **Use stable names, not changing endpoints.** Apps connect to a DNS name that never changes (`app-pg.db.prod.internal` or the Aurora global writer endpoint). Failover moves that name; it does not rewrite application config.
4. **Fence before you promote.** Block writes to the old primary before the new one accepts writes. A split brain does more damage than the outage.
5. **Run the recovery from the recovery region.** Runbooks, automation, IAM break-glass, CI/CD, secrets and the runbook document itself must all work while the primary region is down (static stability).
6. **Every step writes a timestamp.** RTO and RPO are computed from machine-recorded events, not reconstructed from chat afterwards.
7. **Collect evidence as a side effect of execution.** Evidence goes to WORM storage as the steps run, not as a manual task after the event.
8. **Send comms from templates, on a cadence, with one owner.** Nobody writes customer-facing wording from scratch during an incident.
9. **An untested runbook does not exist.** Every runbook has a drill date, a measured RTO/RPO and an owner. If it is stale, it is red on the dashboard.
10. **Every execution improves the runbook.** Every deviation becomes a backlog item with an owner and a due date.

## Quick start (for the capstone)

1. Fill in [`docs/00`](docs/00-dr-strategy-and-principles.md) §2 (tiering and targets) with real business numbers.
2. Map your current runbook against [`docs/02`](docs/02-runbook-standards.md) using the scorecard in [`docs/08`](docs/08-capstone-runbook-optimization.md).
3. Replace the placeholders in [`runbooks/RB-DR-RDS-001`](runbooks/RB-DR-RDS-001-postgres-regional-failover.md) and [`automation/`](automation/).
4. Run a **UAT drill** with [`templates/reports/execution-tracker.csv`](templates/reports/execution-tracker.csv) as a fallback tracker. Measure the baseline RTO/RPO.
5. Apply the optimization backlog, re-drill, and compare the before/after KPIs.

## Naming conventions used in examples

| Item | Primary (Region A) | DR (Region B) |
|---|---|---|
| AWS region | `eu-west-1` | `eu-central-1` |
| RDS instance | `app-pg-prod-euw1` | `app-pg-prod-euc1` (cross-region read replica) |
| Aurora (alt.) | global cluster `app-pg-global`, cluster `app-pg-prod-euw1` | cluster `app-pg-prod-euc1` |
| EKS cluster | `eks-prod-euw1` | `eks-prod-euc1` |
| Stable DB DNS | `app-pg.db.prod.internal` (Route 53 private hosted zone, associated with both VPCs) | same |
| Secret | `prod/app/db` (Secrets Manager, replicated to Region B) | `prod/app/db` (replica) |
| Evidence bucket | `s3://org-dr-evidence-<account>` (Object Lock, log-archive account) | replicated |
