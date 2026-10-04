# 08 — Capstone: RDS Runbook Optimization Method

## 1. Approach

```
 Baseline           Assess               Redesign             Validate            Institutionalise
 ─────────          ──────               ────────             ────────            ───────────────
 Run current   ─►   Scorecard (§2)  ─►   Apply patterns  ─►   UAT drill with  ─►  CI lint, drill
 runbook in UAT     + RTO breakdown      (§3) + backlog       new runbook;        schedule, KPIs
 as-is, measure     (decision / DB /     prioritised by       compare KPIs        dashboard, owner
 T0..T10            app / comms)         RTO-minutes saved    before/after        rotation
```

## 2. Runbook scorecard (score current vs target, 0–3 each)

| # | Criterion | 0 | 3 |
|---|---|---|---|
| 1 | Trigger criteria and decision gates | "Use judgement" | Objective criteria, named approvers, recorded |
| 2 | Step format | Prose | ID, owner, command, expected, verify, budget |
| 3 | Automation | All manual console clicks | Runbook-as-code, manual fallback documented |
| 4 | Secret/endpoint handling | Manual secret edit per app | Stable DNS + ESO + Reloader, one trigger |
| 5 | Fencing / split-brain | Not mentioned | Explicit steps, with waiver record |
| 6 | Verification | "Check app works" | DB write probe + synthetic business transaction |
| 7 | RTO/RPO capture | Reconstructed from chat | Machine-recorded timeline + heartbeat |
| 8 | Evidence | Screenshots, ad hoc | Auto-collected, WORM, manifest with hashes |
| 9 | Communications | Written live | Templates per audience/env/phase, cadence, owner |
| 10 | Failback | "Reverse the steps" | Separate planned procedure with resync + reconciliation |
| 11 | Static stability | Depends on Region A tools | Fully executable from Region B, offline copy |
| 12 | Testing & freshness | Never / unknown | Drilled on schedule, freshness SLO, last results in header |

Total score /36 → maps roughly to maturity: <10 = L1, 10–19 = L2, 20–27 = L3, 28–33 = L4, 34+ = L5.

## 3. Optimization patterns (by expected RTO impact)

| # | Pattern | Typical saving | Effort |
|---|---|---|---|
| P1 | Pre-authorised decision criteria + time-boxed G1 | 15–60 min of "waiting for someone to decide" | Low (policy) |
| P2 | Stable DNS name in the secret (no secret edits); ESO + Reloader | 10–30 min, plus fewer errors | Medium |
| P3 | SSM Automation for promote → wait → DNS → secret epoch bump | 5–20 min, plus audit | Medium |
| P4 | Parallelise: scale up the DR EKS deployments *during* promotion; send comms in parallel with execution | 5–15 min | Low |
| P5 | Warm DR EKS (min replicas running, images pre-pulled, HPA ready) | 5–15 min | Cost trade-off |
| P6 | Pool `maxLifetime` + readiness check on DB writability + JVM DNS TTL | Removes "some pods still broken" long tail | Low |
| P7 | Automated pre-flight (lag, LSN, access, replica secret, DR cluster) | 5–10 min; avoids failed promotion | Low |
| P8 | Comms templates + pre-built status page incident | 10–20 min to first customer comms | Low |
| P9 | Evidence + timeline auto-capture | Hours of post-work; audit-ready | Low |
| P10 | Continuous L2 replica-promotion test | Prevents "it didn't work on the day" | Medium |
| P11 | Aurora Global + global writer endpoint (if T0/failback pain) | Promotion minutes → ~1–2 min; easy failback | High (migration) |

## 4. Before / after (fill in from your drills)

| KPI | Baseline drill | After optimization | Target |
|---|---|---|---|
| Business RTO (`T9 − T0`) | `{{}}` | `{{}}` | ≤ 60 min |
| Decision time | `{{}}` | `{{}}` | ≤ 15 min |
| DB promotion (`T5 − T4`) | `{{}}` | `{{}}` | measured |
| App recovery (`T9 − T5`) | `{{}}` | `{{}}` | ≤ 10 min |
| RPO actual | `{{}}` | `{{}}` | ≤ 5 min |
| # manual steps | `{{}}` | `{{}}` | ↓ ≥ 60 % |
| # people needed hands-on | `{{}}` | `{{}}` | ≤ 3 |
| Time to first customer comms | `{{}}` | `{{}}` | ≤ 30 min |
| Scorecard /36 | `{{}}` | `{{}}` | ≥ 28 |

## 5. Capstone deliverables checklist
- [ ] Current-state runbook + scorecard + baseline drill timeline
- [ ] Target runbook ([`RB-DR-RDS-001`](../runbooks/RB-DR-RDS-001-postgres-regional-failover.md)) customised
- [ ] Automation (SSM doc, scripts, K8s manifests) deployed to UAT in both regions
- [ ] Comms templates approved by Comms/Customer Success/Legal
- [ ] Evidence bucket + collector working; sample bundle from a drill
- [ ] Before/after KPI table with at least one re-drill
- [ ] Backlog of remaining improvements with owners
