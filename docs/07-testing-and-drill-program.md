# 07 — Testing & Drill Program

## 1. Drill matrix (environment × scenario)

| Scenario | DEV | UAT | PROD |
|---|---|---|---|
| **S1** Multi-AZ failover | n/a | n/a (no Multi-AZ: see gap below) | **Semi-annual**, maintenance window: `aws rds reboot-db-instance --force-failover` (≈ 1–2 min of write outage), then run RB-PROD-S1 Phase 2 |
| **S2** Replica promotion | n/a | **Quarterly**, full runbook incl. FB-S2 (planned mode: drain → lag 0 → promote) | Annual tabletop + validated by UAT. A real PROD drill only with a disposable replica (§2 L2) |
| **S3** Snapshot restore | **Monthly automated** (restore → verify → cutover on a DEV namespace → cleanup) | **Quarterly** incl. cutover + FB-S3S4 | **Quarterly restore test** into an isolated account/VPC (no cutover); the cross-account Vault Lock copy at least annually |
| **S4** PITR | **Monthly automated** (both modes alternately) | **Quarterly** (alternate mode A / mode B) | **Semi-annual** side restore (mode B rehearsal, no cutover) + measure the restore time |
| CP-01 secret cutover + Reloader | Every DEV drill | Every UAT drill | Implicitly in S2/S3/S4 tests; plus the **monthly inventory check** (0 unannotated consumers) |

> **UAT gap for S1:** UAT has no Multi-AZ, so app behaviour during a Multi-AZ failover (DNS caching, pool recovery) is only
> exercised in PROD. Mitigation options (choose one, backlog P12): enable Multi-AZ on UAT for a drill window each quarter,
> or keep the semi-annual PROD maintenance-window S1 drill and treat its result as the S1 baseline.

## 2. Drill ladder (increasing realism)

| Level | Type | What happens |
|---|---|---|
| L1 | **Tabletop** | Walk through the env/scenario runbook against a scenario card; validate roles, gates, comms |
| L2 | **Component test (automated)** | Scheduled pipeline: restore/promote a **disposable** instance → `dr-verify.sh db` → measure `T5 − T4` → delete. Also an ESO/Reloader test: bump a dummy key in a test secret → verify rollout |
| L3 | **Planned scenario drill** | Full runbook incl. cutover, comms, evidence, FB runbook |
| L4 | **Unplanned simulation (game day)** | AWS FIS, or an injected "bad migration", with executors not briefed on the details |
| L5 | **Security restore** | Restore from the cross-account Vault-Locked backup into a clean account; rotated credentials |

## 3. Fault injection ideas

| Scenario | Injection |
|---|---|
| S1 | FIS `aws:rds:reboot-db-instances` with `forceFailover=true` (PROD maintenance window) |
| S2 | Make the primary unreachable from the app/replica path (FIS `aws:network:disrupt-connectivity` on the DB subnets in UAT), or stop the UAT primary (`stop-db-instance` is not allowed while it has a read replica; use the network disruption) |
| S4 | A scripted "bad migration" against a seeded UAT table (e.g. `UPDATE … SET price = 0`), timestamp unknown to the executors |
| CP-01 | Remove the Reloader annotation from one test workload: the pre-flight inventory must catch it |

Always use **stop conditions** (a CloudWatch alarm on the customer-facing SLO) and a change ticket.

## 4. Scoring (every drill report)

| KPI | Target | Source |
|---|---|---|
| Business RTO (`T9 − T0`) | ≤ env/scenario target | timeline |
| RPO actual | ≤ target | KPI report |
| Decision time (`T2 − T1`) | ≤ 15 min (PROD) | timeline |
| Cutover time (`T7 − T6`) | ≤ 10 min | timeline |
| Consumers not reloaded automatically | 0 | `dr-eks-rollout.sh wait` output |
| Parity diffs after restore | 0 | `rds-config-parity.sh` |
| Missing timeline markers | 0 | KPI report |
| Comms on time | 100 % | comms log |
| Deviations without a ticket | 0 | PIR |

## 5. DR maturity model

| Level | Name | Characteristics |
|---|---|---|
| 1 | Ad-hoc | One wiki page; manual console restore; manual secret edits; teams restart pods themselves; RTO unknown |
| 2 | Documented | Step-by-step runbook (generic), tested once, sheet tracking |
| 3 | Repeatable | Env/scenario runbooks, gates, roles, scheduled UAT drills, measured RTO/RPO, comms templates |
| 4 | Automated | SSM docs, scripted cutover + Reloader verification, evidence auto-collected, DEV monthly restore tests, KPI trend |
| 5 | Resilient by design | Continuous L2 tests, FIS game days, cross-region protection, RTO model per DB size, zero manual secret handling |

Typical capstone goal: **Level 2 → Level 4**.
