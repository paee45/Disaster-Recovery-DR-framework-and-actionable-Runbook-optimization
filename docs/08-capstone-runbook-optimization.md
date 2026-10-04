# 08 — Capstone: RDS Runbook Optimization Method

## 1. Approach

```
 Baseline              Assess                  Redesign                 Approve                Institutionalise
 ────────              ──────                  ────────                 ────────               ────────────────
 Review current   ─►   Scorecard (§2) per ─►   Env × scenario      ─►   Desk review +     ─►   CI lint, ISMS document
 runbook in UAT        env × scenario +        runbooks + CP-01..06     SRE lead/CTO PR    control, yearly review,
 (S2/S3/S4) and DEV    RTO breakdown           + automation             approval            risk register
 (S3/S4), measure      (decision / DB /        (backlog §3)
 T0..T10               cutover / validation)
```

## 2. Scorecard (0–3 each; score every runbook in the catalogue)

| # | Criterion | 0 | 3 |
|---|---|---|---|
| 1 | Scenario selection | "Restore the DB" | Decision tree by failure class; never promote for corruption |
| 2 | Env-specific | One generic doc | Separate runbook per env/scenario with env approvers, targets and comms |
| 3 | Step format | Prose | ID, owner, budget, command, expected/verify, ⚠/‖ markers |
| 4 | Gates | Implicit | G1/G2/G3/G4 with named approvers, recorded (SSM `aws:approve`) |
| 5 | **Secret cutover** | Manual console edit, then each team restarts its own pods | Scripted secret update + ESO force-sync + **Reloader rollouts verified**, rollback via AWSPREVIOUS |
| 6 | Consumer coverage | Unknown | Inventory: annotated vs not, CronJobs suspended/resumed, Jobs handled |
| 7 | Fencing | Not mentioned | F1/F2/F3 with snapshot-first and waiver recording |
| 8 | Restore hardening/parity | Defaults | Explicit flags + parity diff + IaC adoption + monitoring re-point |
| 9 | Verification | "App works" | DB checks + restore-point check + 0 sessions on old + synthetic business tx |
| 10 | RTO/RPO capture | From chat | Timeline markers + per-scenario RPO + KPI report |
| 11 | Evidence & comms | Ad hoc | Auto-collected WORM bundle; templates per audience/env/phase |
| 12 | Failback/normalisation & PIR | "Done when app is up" | Separate FB runbook (Multi-AZ, replica, rotation, IaC) + scenario PIR questions |

Total /36: < 10 L1 · 10–19 L2 · 20–27 L3 · 28–33 L4 · 34+ L5 (see [07 §4](07-testing-and-drill-program.md)).

## 3. Optimization backlog (ordered by RTO/risk impact)

| # | Improvement | Benefit | Effort |
|---|---|---|---|
| P1 | Pre-authorised decision criteria + scenario decision tree | Cuts "who decides / which option" time (often 15–60 min) | Low |
| P2 | **Scripted secret cutover + ESO force-sync + Reloader on all consumers** (+ inventory gate in pre-flight) | 10–30 min; removes "some pods still on old DB" | Medium |
| P3 | **Restore hardening + password pre-check** | Prevents failed cutovers (default SG/PG, auth failures after restore) | Low |
| P4 | Fencing F1/F2 scripted | Prevents split-brain / lost writes | Low |
| P5 | SSM documents for S2/S3/S4 with approvals | Speed + audit (approver identity) | Medium |
| P6 | App resilience: DNS TTL, pool `maxLifetime`, DB-aware readiness, DB-independent liveness, `maxUnavailable: 0`, AZ spread | S1 self-healing; smoother Reloader rollouts | Low–Medium |
| P7 | Heartbeat + replica LSN capture | Exact RPO for S2, reconciliation cutoff | Low |
| P8 | Warm-up (`pg_prewarm`) before cutover for S3/S4 | Avoids a "restored but unusably slow" phase | Low |
| P9 | Parity + alarm diff + IaC adoption as standard FB steps | No silent monitoring gaps / Terraform destroying the new primary | Medium |
| P10 | *(Deferred — no testing for now)* Restore tests to measure the S3/S4 restore time against the 30 min RTO | Turns risks R2/R3 into numbers | Medium |
| P11 | *(Deferred — accepted risk R1)* Cross-region protection for PROD (cross-region automated-backup replication is the cheapest option) | Confirmed: the PROD replica is in the same region, so a regional event is not recoverable within RTO/RPO | Medium |
| P12 | *(Deferred — accepted risk R6)* UAT has no Multi-AZ, so S1 cannot be rehearsed. Options when testing is approved: a short Multi-AZ window in UAT, or a PROD maintenance-window failover | S1 app-reconnect behaviour validated | Low |
| P13 | Comms templates pre-approved by the CTO (incl. the data-restore variant) | 10–20 min to first customer comms | Low |

## 4. Before / after KPI table (fill from real events or desk walk-throughs; one table per env/scenario)

| KPI | Baseline | After | Target |
|---|---|---|---|
| Business RTO (`T9 − T0`) | | | per env |
| Decision time (`T2 − T1`) | | | ≤ 15 min PROD |
| DB recovery (`T5 − T4`) | | | measured model |
| Cutover (`T7 − T6`) | | | ≤ 10 min |
| RPO actual | | | per scenario |
| Consumers not reloaded automatically | | | 0 |
| Manual commands typed | | | ↓ ≥ 60 % |
| Parity diffs after restore | | | 0 |
| Time to first customer comms (PROD) | | | ≤ 30 min |
| Scorecard /36 | | | ≥ 28 |

## 5. Capstone deliverables checklist
- [ ] Current-state runbook(s) + scorecard (before) and the new runbooks scored (after)
- [ ] 15 env/scenario runbooks customised (`env/*.env`, identifiers, approvers, targets)
- [ ] Reloader annotations + inventory = 0 unannotated consumers in UAT and PROD
- [ ] SSM documents deployed; executor IAM + K8s RBAC in place
- [ ] All runbooks + comms templates reviewed by the SRE lead and approved by the CTO (PR record)
- [ ] Evidence bucket created; collector validated read-only
- [ ] ISO 27001 scope, control mapping and risk register ([09](09-iso27001-scope.md)) with CTO risk acceptance
- [ ] Residual risks R1–R8 accepted (or treated) by the CTO, with a review date
