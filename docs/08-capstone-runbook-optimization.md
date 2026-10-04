# 08 — Capstone: RDS Runbook Optimization Method

## 1. Approach

```
 Baseline              Assess                  Redesign                 Validate               Institutionalise
 ────────              ──────                  ────────                 ────────               ────────────────
 Run the current  ─►   Scorecard (§2) per ─►   Env × scenario      ─►   DEV → UAT drills  ─►   CI lint, drill calendar,
 runbook in UAT        env × scenario +        runbooks + CP-01..06     with the new runbook;  KPI dashboard, freshness
 (S2/S3/S4) and DEV    RTO breakdown           + automation             before/after KPIs      SLO, owner rotation
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
| P10 | Monthly automated DEV restore test; quarterly UAT S2/S3/S4 drills; PROD S1 drill via `reboot --force-failover` | Measured RTO model, drift caught early | Medium |
| P11 | **Cross-region protection for PROD** (cross-region read replica *or* cross-region automated-backup replication + AWS Backup copy) | Today's PROD topology (same-region replica, `TODO(capstone)`: confirm) does not survive a regional event | Medium–High |
| P12 | **UAT Multi-AZ gap**: S1 cannot be rehearsed in UAT. Options: a short-lived Multi-AZ UAT window per quarter, or a PROD maintenance-window S1 drill | S1 behaviour (app reconnect) validated before a real event | Low |
| P13 | Status page + comms templates pre-approved (incl. the data-restore variant) | 10–20 min to first customer comms; legal-safe wording | Low |

## 4. Before / after KPI table (fill from drills; one table per env/scenario)

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
- [ ] Current-state runbook(s) + scorecard + baseline drill timelines (DEV S3/S4, UAT S2/S3/S4)
- [ ] 15 env/scenario runbooks customised (`env/*.env`, identifiers, approvers, targets)
- [ ] Reloader annotations + inventory = 0 unannotated consumers in UAT and PROD
- [ ] SSM documents deployed; executor IAM + K8s RBAC in place
- [ ] Comms templates approved (Comms / Customer Success / Legal), incl. the data-restore variant
- [ ] Evidence bucket + a sample bundle from a drill
- [ ] Before/after KPI tables with at least one re-drill per scenario
- [ ] Residual-risk statement (P11/P12) presented to leadership with a recommendation
