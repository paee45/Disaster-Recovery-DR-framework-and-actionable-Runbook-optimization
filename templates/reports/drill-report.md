# DR Drill Report — {{DR_ID}}

| Field | Value |
|---|---|
| Environment / scenario / type | {{DEV/UAT/PROD}} / {{S1–S4, mode}} / {{L2 automated · L3 planned · L4 game day}} |
| Runbook / automation | RB-{{ENV}}-{{scenario}} v{{x}} (+ FB runbook) · SSM v{{y}} · git {{sha}} |
| Date / window | {{date}} {{hh:mm}}–{{hh:mm}} UTC · Change {{CHG}} |
| Roles | IC {{}} · Exec {{}} · DBA {{}} · Comms {{}} · Scribe {{}} · Observers {{GRC/auditor}} |
| Scenario | {{e.g. FIS network disruption of DB subnets in eu-west-1, executors not briefed}} |
| **Result** | **{{PASS / PASS with findings / FAIL}}** |

## 1. KPIs (from `rto-rpo-report.md`)
| KPI | This drill | Previous | Target | Met |
|---|---|---|---|---|
| Business RTO (T9−T0) | | | | |
| RPO actual | | | | |
| Decision time (T2−T1) | | | ≤ 15 min | |
| DB recovery (T5−T4) | | | model | |
| Cutover (T7−T6) + consumers not auto-reloaded | | | ≤ 10 min / 0 | |
| Parity diffs after restore | | | 0 | |
| App recovery (T9−T5) | | | | |
| Manual steps executed | | | ↓ | |
| Time to first customer comms | | | ≤ 30 min | |
| Evidence completeness | | | 100 % | |

## 2. Timeline (auto-generated from timeline.jsonl, annotated)
| UTC | Marker / step | Note |
|---|---|---|

## 3. Deviations from the runbook
| Step | What happened | Impact (min) | Root cause | Action / ticket | Owner | Due |
|---|---|---|---|---|---|---|

## 4. What went well / what to improve
-

## 5. Runbook changes required (→ PR)
-

## 6. Sign-off
Service Owner {{}} · SRE lead {{}} · GRC {{}} · Date {{}}
Evidence: s3://{{bucket}}/{{prefix}} · manifest sha256 {{hash}}
