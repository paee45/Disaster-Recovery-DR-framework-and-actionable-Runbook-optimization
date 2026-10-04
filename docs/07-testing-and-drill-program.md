# 07 — Runbook Validation (No Scheduled DR Drills)

## 1. Current decision

| Item | Decision (owner: CTO) |
|---|---|
| DR drills / game days | **None scheduled in any environment** (DEV, UAT, PROD). Ad-hoc exercises happen when decided (e.g. **UAT S3 on 2026-08-04**: RTO 39:55, not met → [corrective action plan](10-corrective-action-plan-2026-08-04.md)) |
| PROD | Runbooks only; **no PROD drill** |
| How runbooks are validated | Desk review + static/automated checks (§2), learning from real events (§3) |
| Residual risk | Recorded as **R2** (no regular DR testing) and **R6** (S1 not rehearsable in UAT) in the [risk register](09-iso27001-scope.md#5-dr-risk-register-input-to-61-risk-treatment), accepted by the CTO with a review date |

> **ISO 27001 note:** Annex A **5.30** (ICT readiness for business continuity) and **8.13** (information backup) expect
> continuity and backup arrangements to be *tested*. Not testing is allowed only as a **documented, risk-based decision**.
> That is why R2 exists. Expect an auditor to ask for it, and to ask when it will be re-evaluated.

## 2. Validation without drills (what we do instead)

| Check | What it proves | When |
|---|---|---|
| **Desk review** (PR: SRE lead reviews, CTO approves) | Steps are complete, correct and match the current architecture | Every change; at least every 12 months |
| **Walk-through / read-through** by on-call engineers (no execution) | People know the runbooks exist and understand the roles (A.6.3 awareness) | Yearly and for new on-call members (recommended) |
| CI: `shellcheck`, YAML/JSON lint, `runbook-to-tracker.py` on every runbook | Scripts and step tables are well-formed | Every PR |
| **Read-only pre-flight** against the real env (`dr-preflight.sh replica\|restore`) | Access, replica health, PITR window, snapshots, ESO/Reloader, consumer inventory | After each runbook change (no impact on the environment) |
| `dr-restore.sh … ` with **`DRY_RUN=1`** | The restore commands resolve with the real env profile | After env/profile changes |
| `dr-eks-rollout.sh inventory` | 0 DB consumers without the Reloader annotation | After each app release that adds a workload (could be a CI gate) |
| Backup monitoring (daily automated snapshot exists, `LatestRestorableTime` recent) | The 24 h RPO basis is in place | Continuous (alarms in [04](04-rpo-rto-measurement.md)) |

## 3. Learning from real events

Without drills, the **first real recovery is the baseline measurement**. Every event (any environment, including DEV data
resets with S3/S4) must:
- run with `dr_mark` timestamps, so RTO/RPO are measured, not estimated
- produce a PIR ([CP-06](../runbooks/common/CP-06-post-incident-review.md)) and runbook updates
- update the RTO model in [04](04-rpo-rto-measurement.md) (restore minutes per 100 GB) and re-assess risk R3 (RTO 30 min for S3/S4)

> A DEV data reset done with RB-DEV-S3/S4 is not a "drill". It is normal operations, but it produces real restore-time data at no extra cost.

## 3b. Practice without drills (TICKET-108)
- Yearly read-through of the env/scenario runbooks by every on-call engineer (attendance recorded: ISO 27001 cl. 7.2)
- Hands-on in **DEV** with no impact: `dr-env-check.sh`, `dr-preflight.sh`, `dr-restore.sh … DRY_RUN=1`, `dr-eks-rollout.sh inventory`
- The [CLI quick reference](11-aws-cli-quick-reference.md) is the only command set to learn

## 4. Known gap: S1 cannot be rehearsed in UAT

UAT has no Multi-AZ, so application behaviour during a Multi-AZ failover (DNS caching, pool recovery) is only seen in PROD.
Accepted as **R6**. Options if the decision is revisited:
1. Enable Multi-AZ on UAT for a short window, run `reboot-db-instance --force-failover`, then disable it again (low cost)
2. A PROD maintenance-window failover (`reboot --force-failover`, ≈ 1–2 min of write outage)

## 5. If testing is approved later (catalogue, not a schedule)

| Option | Env | Effort | Value |
|---|---|---|---|
| Automated restore test (S3/S4 into a disposable instance, measure, delete) | DEV | Low | Measures restore time → closes R3 |
| Planned S2 with drain (`DR_MODE=planned`) + FB-S2 | UAT | Medium | Proves the cutover + Reloader path end to end |
| S4 mode B on a seeded "bad change" | UAT | Medium | Practises restore-time selection and surgical repair |
| S1 per §4 | UAT window / PROD | Low | Closes R6 |

Templates for that case already exist: [`drill-report.md`](../templates/reports/drill-report.md) and [`05-planned-drill-notices.md`](../templates/communications/05-planned-drill-notices.md).

## 6. Maturity (for the capstone narrative)

| Level | Name | Characteristics |
|---|---|---|
| 1 | Ad-hoc | No runbooks; manual console restore; manual secret edits; RTO unknown |
| 2 | Documented | A generic runbook |
| **3** | **Repeatable (capstone target)** | Env × scenario runbooks, gates, roles, CP procedures, comms templates, ISMS document control, risks accepted |
| 4 | Automated & measured | SSM documents in use, verified Reloader cutover, evidence auto-collected, measured RTO/RPO from tests or events |
| 5 | Resilient by design | Regular tests, cross-region protection, RTO model per DB size |
