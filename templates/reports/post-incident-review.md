# Post-Incident Review (blameless) — {{DR_ID}}

**Severity:** SEV{{n}} · **Env:** {{}} · **Duration (customer impact):** {{T0→T9}} · **Data impact:** {{none / x s, n records}}
**Authors:** {{}} · **Review meeting:** {{date}} · **Status:** Draft / Reviewed / Published

## 1. Summary (5 lines, readable by executives)

## 2. Impact
| Dimension | Value |
|---|---|
| Customers affected | |
| Duration (business RTO) vs target | |
| Data loss (RPO actual) vs target | |
| SLA/SLO budget consumed | |
| Integrations / partners affected | |

## 3. Timeline (UTC) — from timeline.jsonl + comms log

## 4. Root cause and contributing factors (5 Whys / causal tree)
- Trigger:
- Root cause:
- Contributing (detection, decision, tooling, runbook, people, vendor):

## 5. DR execution assessment
Scenario: {{S1|S2|S3|S4 (mode)}} · Runbook: RB-{{ENV}}-{{…}} v{{x}} · FB runbook: {{…}}

| Segment | Planned budget | Actual | Gap reason |
|---|---|---|---|
| Declare (T0→T1) | | | |
| Decision incl. scenario choice (T1→T2) | | | |
| DB recovery: failover/promote/restore (T4→T5) | | | |
| Secret cutover + Reloader rollouts (T6→T7) | | | |
| Validation to restored (T7→T9) | | | |
| Consumers not auto-reloaded / parity diffs / fencing waivers | | | |

Scenario-specific questions: see [CP-06](../../runbooks/common/CP-06-post-incident-review.md).

## 6. Communications assessment
| Audience | First message (min after T0) | Updates on time (%) | Issues |
|---|---|---|---|

## 7. Action items
| # | Action | Type (prevent/detect/mitigate/process) | Owner | Due | Ticket |
|---|---|---|---|---|---|

## 8. Evidence
s3://{{bucket}}/{{prefix}} · manifest sha256 {{hash}}
