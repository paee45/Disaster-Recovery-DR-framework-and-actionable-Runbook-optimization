# 07 — Testing & Drill Program

## 1. Drill ladder (increasing realism)

| Level | Type | What happens | Env | Cadence (T1) |
|---|---|---|---|---|
| L1 | **Tabletop** | Walk through the runbook verbally against a scenario; validate roles, gates, comms | — | Quarterly / for every new on-call member |
| L2 | **Component test** | Promote a *disposable* replica (create replica → promote → verify → delete); ESO/Reloader restart test | UAT | Monthly (automated, scheduled) |
| L3 | **Planned switchover** | Full runbook, zero data loss, with comms and evidence | UAT → PROD | UAT quarterly; PROD annually (in a maintenance window) |
| L4 | **Unplanned simulation (game day)** | Inject failure with AWS FIS (network disruption of DB subnets, AZ power interruption scenario, Aurora failover action), executors not told the details | UAT; PROD for T0 with high maturity | Semi-annual |
| L5 | **Class B/C restore** | PITR into a new instance, restore from the cross-account Vault-Locked backup into a clean account | UAT / isolated account | Semi-annual |

> **The automated L2 test gives the most value for the least effort.** A scheduled pipeline creates a temporary
> cross-region replica, promotes it, runs `dr-verify.sh`, records the promotion time and deletes the replica.
> This continuously measures `T5 − T4` and catches IAM/parameter-group/KMS drift long before a real event.

## 2. AWS FIS ideas for game days

| Scenario | FIS action / approach |
|---|---|
| Primary DB unreachable from app | `aws:network:disrupt-connectivity` on the DB subnets (scope `all`) in Region A |
| Aurora writer failure | `aws:rds:failover-db-cluster` |
| RDS instance reboot with failover | `aws:rds:reboot-db-instances` (`forceFailover=true`) for the in-region HA baseline |
| EKS node loss | `aws:eks:terminate-nodegroup-instances` |
| Pod-level chaos | `aws:eks:pod-*` actions (e.g. pod network latency/blackhole) |
| AZ impairment | FIS scenario library "AZ Availability: Power Interruption" |

Always set **stop conditions** (a CloudWatch alarm on the customer-facing SLO) and run under a change ticket.

## 3. Drill scoring (put this in every drill report)

| KPI | Target | Source |
|---|---|---|
| Business RTO (`T9 − T0`) | ≤ tier RTO | timeline |
| RPO actual | ≤ tier RPO | heartbeat |
| Decision time (`T2 − T1`) | ≤ 15 min | timeline |
| Manual steps executed | ↓ each drill | runbook tracker |
| Runbook deviations | 0 *unrecorded*. Every deviation becomes a ticket | PIR |
| Steps with missing evidence | 0 | manifest check |
| Comms on time (% sent ≤ committed time) | 100 % | comms log |
| Time to first customer comms | ≤ 30 min | comms log |

## 4. DR maturity model (use it to place the current state and the capstone target)

| Level | Name | Characteristics |
|---|---|---|
| 1 | Ad-hoc | Wiki page, tribal knowledge, never tested, RTO unknown |
| 2 | Documented | Step-by-step runbook, tested once, manual secret edits and restarts, sheet tracking |
| 3 | Repeatable | Standard template, gates, roles, scheduled UAT drills, measured RTO/RPO, comms templates |
| 4 | Automated | Runbook-as-code, ESO/Reloader, evidence auto-collected, drills in PROD, KPIs trending |
| 5 | Resilient by design | Continuous automated DR validation (L2 daily), game days with FIS, RTO from SLOs, ARC-driven traffic control, chaos culture |

Typical capstone goal: **Level 2 → Level 4** for the RDS runbook.
