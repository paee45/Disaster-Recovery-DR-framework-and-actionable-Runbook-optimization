# 03 — Runbook Execution Media & Tooling

The question is not "sheet or tool". There are **three separate jobs**, and each needs the right medium:

1. **Author & version** the procedure → *source of truth*
2. **Execute** the steps → *automation engine*
3. **Coordinate & record** people, decisions, timeline and comms → *incident console*

Most failures happen when one medium does all three. A spreadsheet is the usual example: it is used as
procedure, execution log and status board, and does all three badly.

## 1. Options compared

Score: 1 (poor) – 5 (excellent). "Risk" = operational risk (higher score = lower risk).

| Option | Risk | Audit | Speed | Ease | Works when Region A is down? | Best used for |
|---|---|---|---|---|---|---|
| **A. AWS SSM Automation (runbook-as-code)** | 4 | 5 (CloudTrail, execution history, approver identity) | 5 | 3 | Yes, if the doc is deployed in Region B | Executing AWS-side steps; approval gates |
| **A2. Route 53 ARC Region switch** | 4 | 5 | 5 | 4 | Yes (designed for it) | T0 multi-resource regional orchestration (Aurora global, EKS scaling, R53) |
| **A3. AWS SSM Incident Manager** | 4 | 4 | 4 | 4 | Yes (cross-region replication set) | Response plans, engagement, timeline. **Check current service availability for new customers before you standardise on it** |
| **B. Incident platforms** (PagerDuty + Process/Runbook Automation, incident.io, FireHydrant, Rootly, Jira Service Management, Datadog Incident Mgmt) | 4 | 4–5 | 4 | 5 | SaaS. Check vendor region independence | Role assignment, Slack/Teams-native timeline, status page, stakeholder updates, workflow triggers |
| **B2. Runbooks-in-Git (Markdown + scripts, rendered in Backstage/Confluence)** | 3 | 4 (PR history) | 3 | 4 | Yes, if mirrored (PDF in S3 Region B, local clone) | Source of truth, review, versioning |
| **B3. Jupyter / Notebook-style runbooks** | 3 | 3 | 4 | 3 | Depends on host | Diagnostic steps; not for gated irreversible actions |
| **C. Shared spreadsheet (Google Sheets / Excel Online)** | 2 | 2 (editable history, no identity on gates, easy to overwrite) | 2 | 5 | SaaS. Usually yes | Multi-team **manual** cutovers, drill tracking, **fallback** |
| **D. Printed / PDF checklist** | 3 | 1 | 2 | 4 | **Always** | Last-resort fallback when all tooling is down |

### Why a spreadsheet alone is not enough for PROD DR
- There is no gate enforcement. Anyone can tick "Promote" without approval.
- Timestamps are typed by hand (time zones, rounding). RTO evidence will not hold up in an audit.
- Concurrent edits get lost, and the sheet cannot run commands.
- **When a sheet is still useful:** a large multi-team, multi-vendor cutover (many teams, a few steps each) with UAT users and partners who will not get access to your incident tool. In that case, make the sheet **generated from** the Git runbook (not hand-written), lock the structure, protect columns, and export it to the evidence bucket at closure. Template: [`templates/reports/execution-tracker.csv`](../templates/reports/execution-tracker.csv).

## 2. Recommended hybrid (target state)

```
 ┌──────────────── SOURCE OF TRUTH ───────────────────┐
 │ Git: runbooks/*.md + automation/* (PR-reviewed)    │──CI──► publish: incident-tool runbook,
 │ version pinned: runbook vX ↔ SSM doc vY ↔ git SHA  │        PDF → s3 (Region B), changelog → chat
 └───────────────────────┬────────────────────────────┘
                         │ deploys (IaC, both regions)
 ┌───────────────────────▼────────────────────────────┐
 │ EXECUTION ENGINE                                   │
 │  SSM Automation "DR-RdsPostgresRegionalFailover"   │  aws:approve = gates G2/G3
 │  (or ARC Region switch plan for T0)                │  every step → CloudTrail + timeline event
 │  ESO + Reloader in EKS (self-healing secret sync)  │
 └───────────────────────┬────────────────────────────┘
                         │ webhooks / EventBridge
 ┌───────────────────────▼────────────────────────────┐
 │ INCIDENT CONSOLE (people & comms)                  │
 │  Incident platform + Slack/Teams channel           │  roles, timeline, status page,
 │  /dr declare → creates channel, bridge, Jira       │  templated stakeholder updates
 └───────────────────────┬────────────────────────────┘
                         │ on close
 ┌───────────────────────▼────────────────────────────┐
 │ EVIDENCE: S3 Object Lock (log-archive acct)        │
 │ timeline.jsonl, SSM execution JSON, CloudTrail,    │
 │ kubectl outputs, SQL outputs, comms log, manifest  │
 └────────────────────────────────────────────────────┘
   FALLBACKS: generated sheet tracker (multi-team), offline PDF (total tooling loss)
```

**Selection guidance**

| Situation | Execution | Console |
|---|---|---|
| You already run Slack + Jira + Datadog (common enterprise stack) | SSM Automation | Datadog Incident Management or Jira Service Management + Slack channel; Statuspage for customers |
| You already have PagerDuty | SSM Automation (triggered from PagerDuty Runbook Automation jobs) | PagerDuty Incident Workflows + Slack |
| T0 with Aurora Global | ARC Region switch (assess) or SSM | Same as above |
| Early maturity, many manual steps | Git runbook + scripts, executed by a human | Incident channel + **generated** sheet tracker. Plan to retire the sheet once steps are automated |

## 3. Minimum tooling bill of materials

| Capability | Tool (examples) |
|---|---|
| DB failover | `aws rds promote-read-replica` / `failover-global-cluster` via SSM Automation |
| Traffic switch | Route 53 ARC routing controls / Route 53 failover records |
| Secret sync to EKS | External Secrets Operator + IRSA / EKS Pod Identity |
| Automatic restarts | Stakater Reloader |
| GitOps state for DR cluster | Argo CD / Flux (ApplicationSet targeting both clusters) |
| Fault injection for drills | AWS Fault Injection Service (FIS) |
| Observability | CloudWatch + Prometheus/Grafana or Datadog; synthetic checks (CloudWatch Synthetics / Datadog Synthetics) |
| Evidence | S3 Object Lock + `dr-collect-evidence.sh` |
| Backups (class B/C) | AWS Backup with cross-account copy + Vault Lock |
