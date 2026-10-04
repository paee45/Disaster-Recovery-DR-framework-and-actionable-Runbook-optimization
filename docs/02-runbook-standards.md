# 02 — Runbook Standards

A runbook is an **executable procedure for a tired person at 03:00 who has never done this before**. Write it
for that reader.

## 1. Mandatory anatomy

Every DR runbook (template: [`templates/runbook-template.md`](../templates/runbook-template.md)) has these sections, in this order.
Repeated procedures (secret cutover, verification, parity, fencing, evidence, PIR) live once in `runbooks/common/CP-0x` and are referenced by ID:

| # | Section | Purpose |
|---|---|---|
| 0 | **Header / metadata** | ID, version, owner, approver, last drill date, measured RTO/RPO, tier, environments, linked automation version |
| 1 | **When to use / when NOT to use** | Trigger criteria, and the failure classes this runbook does *not* cover (link to the PITR or ransomware runbooks) |
| 2 | **Roles (RACI)** | IC, Executor (Ops lead), Scribe, Comms lead, DBA, App owner, Approver |
| 3 | **Prerequisites** | Access (break-glass role), tools, links, pre-checks, comms channel |
| 4 | **Decision gates** | Go/no-go criteria with named decision makers |
| 5 | **Phased procedure** | Phases → steps (format below) |
| 6 | **Abort / rollback points** | What can be undone, until when, and how |
| 7 | **Verification & exit criteria** | Objective conditions that close the runbook |
| 8 | **Evidence checklist** | What must be in the evidence bucket before closure |
| 9 | **Comms checkpoints** | Which template is sent at which step |
| 10 | **Change log** | Version history, with links to the drill/PIR that caused each change |

## 2. Step format (non-negotiable)

Each step is one row or block containing:

```
[P2-S05] Promote read replica                              ⏱ budget 1 min    👤 Executor   ⚠ IRREVERSIBLE
  Pre-condition : Gate G2 approved (IC + DBA), fencing (CP-04) done or waived (record why)
  Action        : automation  ▸ SSM DR-RdsPromoteReplica step "PromoteReplica"  |  manual ▸ aws rds promote-read-replica ...
  Expected      : DBInstanceStatus transitions modifying → available; pg_is_in_recovery() = false
  Verify        : ./automation/scripts/dr-verify.sh wait-promoted
  If fails      : retry once after 2 min; then escalate DBA + AWS Support (Sev "Business-critical system down")
  Evidence      : auto (CloudTrail PromoteReadReplica, describe-db-instances JSON, timeline event)
  Timeline mark : dr_mark T4 (start) / T5 (writable)
```

Writing rules:

- **One action per step.** If a step needs "and", split it.
- **Copy-paste-safe commands.** Use only variables set in a single "env block" at the top. No `<replace-me>` inside commands.
- **Every step has an expected result and a verification.** "Run X" without "you should see Y" is not allowed.
- **Time budget per step.** The sum of the budgets is the *designed* RTO. Compare it to the measured RTO after each drill.
- **Mark irreversible steps** (⚠) and put a gate before them.
- **Automation-first, manual fallback.** Each automated step names the equivalent manual command for when automation fails.
- **No knowledge outside the runbook.** If a step depends on "ask Bob", that is a defect.
- **Parallelism is explicit.** Mark steps that can run in parallel (`‖`). They are the biggest source of RTO reduction.

## 3. Gates

| Gate | Position | Decision | Who |
|---|---|---|---|
| **G1 — Declare & choose** | End of Phase 1 | Scenario (S2/S3/S4, mode A/B) + snapshot/restore time + data-loss estimate accepted | Env approvers ([00 §3](00-dr-strategy-and-principles.md)) |
| **G2 — Point of no return** | Before `promote-read-replica` (S2) | Fencing status accepted, final LSN/heartbeat captured | IC + DBA |
| **G3 — Cutover** | Before the secret update (S2/S3/S4) | New DB validated (restore point, parity, password pre-check), old instance fenced or planned | IC (+ App owner) |
| **G4 — Declare restored** | After verification (CP-02) | Synthetic business transactions pass, error rate within SLO | IC |
| **FB-G0 — Failback model** | Start of FB runbook (separate change) | Forward-fix vs return-to-original; maintenance window if downtime | Service Owner + DBA |

Implement gates as `aws:approve` steps (SSM Automation) or as `DECISION:` messages captured by the incident tool,
so the approver identity and timestamp are recorded automatically.

## 4. Roles (incident command model)

| Role | Responsibility | Must NOT |
|---|---|---|
| **Incident Commander (IC)** | Owns decisions, gates, and the timeline; runs the bridge | Type commands |
| **Executor / Ops lead** | Runs automation and manual steps; reads expected results aloud | Make go/no-go decisions alone |
| **Second pair of eyes** | Verifies each irreversible command *before* Enter (four-eyes) | — |
| **Scribe** | Keeps the timeline in the incident tool (most of it is auto-marked) | — |
| **Comms lead** | Sends templates on cadence; is the only voice to customers and vendors | Improvise wording on data loss/security |
| **DBA** | Lag/LSN assessment, promotion, data reconciliation | — |
| **App owner(s)** | App health, smoke tests, business validation | — |
| **Exec approver** | Accepts data loss / customer impact | — |

Rotate roles in drills. Each role needs at least 2 trained people (no single point of failure in people).

## 5. Lifecycle and governance

- **One runbook per environment × scenario** (DEV/UAT/PROD × S1–S4 + FB). Env differences (approvers, Multi-AZ steps, comms, targets) are explicit, not "if PROD then…" prose.
- **Source of truth:** Markdown in Git, with PR review by SRE + DBA + App owner. Version bump with each merged change (`vMAJOR.MINOR`).
- **Linked automation:** the runbook header pins the SSM document version and script git SHA. CI checks that they match.
- **Freshness SLO:** a T0/T1 runbook drilled > 90 days ago (UAT) or > 365 days (PROD) is red on the DR dashboard.
- **Automated linting in CI:** every step has an ID, expected result and verify; no TODOs in released versions; links resolve; commands pass `shellcheck` and `cfn-lint`/`yamllint`.
- **Distribution:** on release, CI publishes (1) the incident tool runbook, (2) a PDF to the DR-region S3 bucket, (3) the change log to the team channel.
