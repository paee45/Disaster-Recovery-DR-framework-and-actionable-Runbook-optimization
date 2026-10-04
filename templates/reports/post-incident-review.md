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
| Phase | Planned budget | Actual | Gap reason |
|---|---|---|---|
| P1 Pre-flight + G1 | 15 | | |
| P2 DB failover | 15 | | |
| P3 Compute | 10 | | |
| P4 Verify → T9 | 15 | | |

## 6. Communications assessment
| Audience | First message (min after T0) | Updates on time (%) | Issues |
|---|---|---|---|

## 7. Action items
| # | Action | Type (prevent/detect/mitigate/process) | Owner | Due | Ticket |
|---|---|---|---|---|---|

## 8. Evidence
s3://{{bucket}}/{{prefix}} · manifest sha256 {{hash}}
