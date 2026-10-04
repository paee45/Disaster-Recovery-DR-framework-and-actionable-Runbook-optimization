# 10 — Corrective Action Plan: UAT DR Exercise 2026-08-04 (RDS PostgreSQL snapshot restore)

| Document control | |
|---|---|
| Source | ISMS DR Exercise Report v1.0, exercise date 2026-08-04 (UAT, scenario S3: snapshot restore) |
| ISO/IEC 27001:2022 | Clause **10.2** nonconformity & corrective action · A.5.27 learning from incidents · A.5.30 ICT readiness |
| Owner | SRE lead · Approved by: CTO |
| Status | v0.1-draft. Owners, due dates and ticket links are `{{…}}` |

## 1. Result recap

| Objective | Target | Actual | Result |
|---|---|---|---|
| RTO (connection lost → connection restored) | 30 min | **39 min 55 s** (10:30 → 11:09) | ❌ **Nonconformity** (+9 min 55 s) |
| RPO | 24 h | 17 h | ✅ Met |
| Failover to restored DB + E2E transaction | Works | Works | ✅ |
| Failback to original + E2E transaction | Works | Works | ✅ |

**Stated causes of the RTO miss:** manual execution steps, script usability issues, time spent clarifying runbook instructions.
DB size was 590 MB, so the restore itself was not the problem. **The overrun came from process and tooling, not AWS**, and that makes it correctable.

## 2. Root cause analysis

| # | Finding (from the report) | Root cause (why it happened) | Category |
|---|---|---|---|
| F1 | Manual restarts of application services | No automatic link between a DB secret change and the pods that use it; no list of consumers | Automation |
| F2 | Discovery/verification manual (finding deployments that use `[app]-db-credentials`) | No inventory tooling | Automation |
| F3 | Only the first security group restored; backup retention fixed by hand | Script read `SecurityGroups[0]`; restore APIs do not carry retention over; no post-restore check | Script defect |
| F4 | Env variables inconsistent (`<KUBE_CONTEXT>` edited by hand, `POSTGRES_DB_HOST` missing) | No single env profile; placeholders inside commands; no pre-start validation | Process / tooling |
| F5 | Ambiguous runbook (undefined `OLD_DB`, no explicit "wait until available") | Runbook not written in a strict step format (variables, expected result, wait conditions) | Documentation |
| F6 | Script quoting errors, hard-coded defaults | Scripts built CLI arguments as strings; values embedded in scripts | Script defect |
| F7 | CLI faster than the console, but limited CLI familiarity | No CLI quick reference; procedures rarely practised | Competence (A.6.3, cl. 7.2) |
| F8 | Verification scripts outdated for the current schema | Hard-coded schema assumptions in verification scripts | Documentation / tooling |
| F9 | Unnecessary checks (user-login verification) added overhead | No defined minimum E2E check set | Process |
| F10 | Form tool unintuitive during execution; copying commands inconvenient | Execution medium chosen for evidence, not for execution | Tooling |
| F11 | External parties not consistently notified; no timelines/channels in the playbook | No communication protocol, no owner, no distribution lists, no SLA timeline | Communication |
| F12 | Roles and responsibilities for comms unclear | Comms role not assigned at the start; no backup | Communication |

**Additional observations from reviewing the report** (recommend adding them to the report as findings):

| # | Observation | Why it matters | Action |
|---|---|---|---|
| F13 | Start/end times (10:30/11:09) have **no time zone**; "latest transaction 2026-08-03 10:28:29 UTC" | The RTO/RPO evidence is ambiguous for an auditor | UTC everywhere (`dr_mark`, `dr_run`) → TICKET-107 |
| F14 | **RPO 17 h is not traceable**: the latest transaction (08-03 10:28 UTC) is ~24 h before the exercise; the snapshot creation time is not listed | The RPO must be derived from `SnapshotCreateTime`, which is recorded automatically now (`RPO_SNAPSHOT`) | TICKET-107 |
| F15 | "The running database was paused": an RDS instance **with a read replica cannot be stopped** (UAT has one) | The outage-simulation method must be documented and repeatable | Use the quarantine SG (`dr-fence-instance.sh quarantine`), see CP-07 → TICKET-101 |
| F16 | No phase breakdown of the 39:55 | The RTO cannot be optimised without knowing where time went | Phase timers (`dr_phase`) → TICKET-107 |
| F17 | Approver "Engineering Director" vs the ISMS approver for DR documents | Inconsistent authority in the ISMS | Align roles (report template + [09](09-iso27001-scope.md)) |

## 3. Corrective actions (ready to paste into the tickets)

Status legend: **Delivered** = implemented in this repository, pending SRE lead review / CTO approval · **Open** = needs work outside the repo.

### TICKET-101 — Runbook: promotion / Multi-AZ procedures + troubleshooting
| | |
|---|---|
| Findings | F5, F15 (+ the scope request in the report) |
| Corrective action | Separate runbooks per env × scenario: S1 Multi-AZ post-event, S2 replica promotion, S3 snapshot, S4 PITR, plus failback runbooks; strict step format; troubleshooting guide; documented outage-simulation method |
| Delivered | [`runbooks/README.md`](../runbooks/README.md) (catalogue + decision tree), `runbooks/prod/RB-PROD-S1…`, `RB-PROD-S2…`, `RB-UAT-S2…`, [CP-07 troubleshooting](../runbooks/common/CP-07-troubleshooting.md) |
| Definition of done | Runbooks merged after review by the SRE lead and approval by the CTO; every step has an owner, a time budget, a command and an expected result; no undefined variables (`dr-env-check.sh` passes) |
| Owner / due | `{{}}` / `{{}}` |

### TICKET-102 — Automation of manual steps + Kubernetes restart on secret change
| | |
|---|---|
| Findings | F1, F2 |
| Corrective action | Deploy **Stakater Reloader** (HA) and annotate every workload that uses the DB secret. The cutover script updates the secret, forces the ESO sync, **verifies that each consumer was restarted** (falls back to `rollout restart`), and handles CronJobs. The inventory command lists every consumer and whether it is annotated |
| Delivered | [`automation/k8s/reloader-values.yaml`](../automation/k8s/reloader-values.yaml), [`deployment-dr-snippet.yaml`](../automation/k8s/deployment-dr-snippet.yaml), [`dr-secret-cutover.sh`](../automation/scripts/dr-secret-cutover.sh), [`dr-eks-rollout.sh`](../automation/scripts/dr-eks-rollout.sh) (`inventory`, `wait`, `restart`, `suspend/resume-cronjobs`), SSM documents |
| Open | Install Reloader in UAT/PROD; add the annotation `secret.reloader.stakater.com/reload: "[app]-db-credentials"` to all consumers (Helm charts); consider a CI check that fails when a workload uses the secret without the annotation |
| Definition of done | `dr-eks-rollout.sh inventory` shows **0** `reloader=NO` in UAT and PROD; one cutover in UAT with **0 manual restarts** |
| Owner / due | `{{}}` / `{{}}` |

### TICKET-103 — Script fixes: SGs, retention, env variables, no hard-coded defaults
| | |
|---|---|
| Findings | F3, F4, F6 |
| Corrective action | Restore is built from a **captured baseline** of the source (`dr-restore.sh capture`: full `describe-db-instances`, all tags, `pg_settings`), passed as `--cli-input-json`: **all** SGs, subnet/parameter/option group, class, Multi-AZ, storage, port, IAM auth, log exports, CA, backup retention **7 (not the CLI default 1)** + window, deletion protection, all tags. `harden` converges what a restore cannot set (maintenance window, PI, monitoring, roles) and reboots on `pending-reboot`; **`validate`** compares every attribute with the baseline and `validate-pg` every `pg_settings` value — a gate before cutover. Env overrides are explicit and reported. One env profile per environment holds every variable (`EKS_CONTEXT`, `K8S_SECRET`, `K8S_HOST_KEY=POSTGRES_DB_HOST`, …). `dr-env-check.sh` validates the profile before starting (placeholders, account, kube context, secrets). CLI arguments are built as arrays (no quoting issues); shellcheck-clean |
| Delivered | [`dr-restore.sh`](../automation/scripts/dr-restore.sh) (`capture`, `plan`, `snapshot`, `pitr`, `wait`, `harden`, `validate`, `validate-pg`), [`rds-config-parity.sh`](../automation/scripts/rds-config-parity.sh), [`env/*.env.example`](../env/), [`dr-env-check.sh`](../automation/scripts/dr-env-check.sh) |
| Definition of done | `dr-restore.sh validate` → `VALIDATED` on a UAT restore **without manual fixes**; baseline capture scheduled daily (stored + S3); `dr-env-check.sh` PASS in UAT and PROD |
| Owner / due | `{{}}` / `{{}}` |

### TICKET-104 — Database verification scripts for the current environment
| | |
|---|---|
| Findings | F8 |
| Corrective action | Remove schema assumptions from code: generic checks (`20-postfailover-verify.sql`: writable, not read-only, invalid indexes, connections), a restore-point check that discovers timestamp columns, and **row-count comparison old vs new for the tables listed in `VERIFY_TABLES`** in the env profile |
| Delivered | [`automation/sql/20-postfailover-verify.sql`](../automation/sql/20-postfailover-verify.sql), [`05-restore-point-check.sql`](../automation/sql/05-restore-point-check.sql), `dr-verify.sh compare-counts` |
| Open | Backend lead fills in `VERIFY_TABLES` for DEV/UAT/PROD (the 3–5 business-critical tables) |
| Definition of done | All checks run without errors against UAT and PROD (read-only for PROD) |
| Owner / due | `{{}}` / `{{}}` |

### TICKET-105 — DR communication protocol & stakeholder timelines
| | |
|---|---|
| Findings | F11, F12 |
| Corrective action | Communication ownership (IC / Comms lead / CTO, with backups) and primary/secondary channels; an **SLA-aligned notification timeline** per audience for real events and exercises; an exercise broadcast workflow (T−5, T−2, start, end, T+5); a maintained distribution list register; templates per audience and phase (incl. data-restore wording) |
| Delivered | [`docs/06 §5`](06-communications.md#5-communication-protocol-ticket-105), [`templates/communications/01…06`](../templates/communications/) incl. [`06-distribution-lists.md`](../templates/communications/06-distribution-lists.md) |
| Open | Fill in contractual notice periods per customer/partner (Account management → Comms lead); populate the distribution lists |
| Definition of done | Lists and timelines populated and CTO-approved; next exercise has **100 %** of required notices sent before the start (comms log) |
| Owner / due | `{{}}` / `{{}}` |

### TICKET-106 — Lighter documentation & evidence collection
| | |
|---|---|
| Findings | F9, F10 |
| Corrective action | Execute from the Git/wiki runbook (copy-friendly commands), not the form tool. Evidence is collected **automatically** (`dr-collect-evidence.sh`: timeline, phase times, CloudTrail, RDS events, secret version metadata, rollouts, SQL outputs, SHA-256 manifest). The form tool, if kept, only receives the final report + the evidence link. A defined **minimum evidence set** and **minimum E2E check set** (no user-login check) |
| Delivered | [CP-05](../runbooks/common/CP-05-evidence-and-closure.md) (minimum evidence set), [E2E validation playbook](../templates/reports/e2e-validation-playbook.md), [`runbook-to-tracker.py`](../automation/scripts/runbook-to-tracker.py) (if a checklist is still wanted) |
| Definition of done | Evidence for the next exercise produced by the script in ≤ 10 min after the end; no evidence captured manually during the RTO clock |
| Owner / due | `{{}}` / `{{}}` |

### TICKET-107 — Automated RTO tracking & E2E test playbook
| | |
|---|---|
| Findings | F13, F14, F16 (+ the report's request) |
| Corrective action | `dr_mark` (T0…T10, UTC) and **`dr_phase start/end`** timers in every runbook phase, plus `dr_summary` (per-phase durations, elapsed since T0 vs the 30 min target). RTO/RPO are computed by `dr-rto-rpo-calc.py`; the RPO comes from the recorded `SnapshotCreateTime`. Evidence standard: UTC, visible clock on screenshots, command output captured with timestamps. An E2E playbook with URLs, test hardware/chargers, QR codes and dashboards |
| Delivered | [`dr-lib.sh`](../automation/scripts/dr-lib.sh) (`dr_mark`, `dr_run`, `dr_phase`, `dr_summary`), [`dr-rto-rpo-calc.py`](../automation/scripts/dr-rto-rpo-calc.py), [E2E playbook](../templates/reports/e2e-validation-playbook.md) |
| Open | Backend lead fills in the playbook values (URLs, devices, QR codes) |
| Definition of done | The next exercise report shows a per-phase table generated from the timeline, and RTO/RPO computed from recorded timestamps |
| Owner / due | `{{}}` / `{{}}` |

### TICKET-108 — Team familiarity with AWS CLI and DR procedures
| | |
|---|---|
| Findings | F7 |
| Corrective action | An AWS CLI quick reference for exactly the commands in the runbooks; **practice without a formal drill schedule**: a yearly read-through of the runbooks per on-call engineer, plus hands-on practice in **DEV** with `DRY_RUN=1` and the read-only checks (`dr-env-check.sh`, `dr-preflight.sh`), which change nothing |
| Delivered | [`docs/11-aws-cli-quick-reference.md`](11-aws-cli-quick-reference.md), [`docs/07`](07-testing-and-drill-program.md) |
| Open | CTO decides the practice format; record attendance (ISO 27001 cl. 7.2 competence evidence) |
| Definition of done | Every on-call engineer has completed one read-through + one DEV dry-run (attendance record) |
| Owner / due | `{{}}` / `{{}}` |

## 4. Expected RTO after the corrective actions (UAT S3, ~0.6 GB)

| Phase | Before (2026-08-04)* | Target budget | What removes the time |
|---|---|---|---|
| Prepare + decision | unknown | 3 min | Env profile + env check done **before** the clock; snapshot chosen by script |
| Restore to available | unknown | ~12 min | AWS time (re-measure; `dr-restore.sh wait` reports it) |
| Harden + DB verification | manual SG/retention fixes, outdated scripts | 4 min | `harden` + parity diff; generic verification |
| Cutover (secret → pods) | manual restarts + discovery | 5 min | Reloader + `dr-secret-cutover.sh apply` |
| App verification | extra checks (login) | 5 min | Minimum E2E playbook |
| Close | form navigation during the drill | 1 min | Evidence collected automatically after T10 |
| **Total** | **39 min 55 s** | **≈ 30 min** | |

\* No phase breakdown was recorded on 2026-08-04 (F16). The restore phase dominates the remaining budget: if it takes longer
than 12 min, the 30 min target stays at risk (register risk R3, [09](09-iso27001-scope.md)).

## 5. Effectiveness review (clause 10.2 f)

ISO 27001 requires reviewing whether corrective actions were effective. Choose one (CTO decision):

| Option | How | Effectiveness criteria |
|---|---|---|
| **A (recommended)**: one verification exercise in UAT after TICKET-102/103/107 are done (a one-off, not a schedule) | Re-run [RB-UAT-S3 v1.1](../runbooks/uat/RB-UAT-S3-snapshot-restore.md) + exercise failback | RTO ≤ 30 min; 0 manual pod restarts; 0 manual SG/retention fixes; 0 runbook clarification questions; 100 % notices sent; evidence bundle auto-generated |
| B: review at the next real event | Use the KPI report of the next S2/S3/S4 event (any env) | Same criteria |
| C: desk verification only | SRE lead verifies the deliverables + `DRY_RUN` in UAT | Deliverables exist and run; **RTO not proven** (risk R3 stays open) |

## 5b. Verification of the delivered scripts (before any re-exercise)

`tests/local/run-tests.sh` exercises every script end to end on k3s + LocalStack + moto + real Postgres + ESO + Reloader: **48/48 pass**
([last run](../tests/local/last-run-report.md)). It covers TICKET-102 (app-a/app-b restarted by Reloader, app-c not annotated, so it is detected,
left alone or restarted by policy), TICKET-103 (all 3 SGs copied, retention hardened, env check, wrong account/cluster refused) and
TICKET-107 (phase timers, evidence, KPI report). The tests also found and fixed 3 real script bugs: DB password lost in a subshell,
un-fence failing on a read-only DB, and a Reloader values setting (`watchGlobally: false`) that would never have restarted app pods.
Next: `tests/aws/sandbox-test.sh readonly`, then `full` in UAT, which also measures the real snapshot-restore time (risk R3).

## 6. Tracking

| Ticket | Delivered in repo | Open items | Owner | Due | Status |
|---|---|---|---|---|---|
| TICKET-101 | ✔ | Review/approval | `{{}}` | `{{}}` | In review |
| TICKET-102 | ✔ | Install Reloader, annotate workloads | `{{}}` | `{{}}` | Open |
| TICKET-103 | ✔ | Fill in env profiles | `{{}}` | `{{}}` | In review |
| TICKET-104 | ✔ | `VERIFY_TABLES` per env | `{{}}` | `{{}}` | Open |
| TICKET-105 | ✔ | Contract timelines, lists | `{{}}` | `{{}}` | Open |
| TICKET-106 | ✔ | Decide the role of the form tool | `{{}}` | `{{}}` | In review |
| TICKET-107 | ✔ | E2E playbook values | `{{}}` | `{{}}` | Open |
| TICKET-108 | ✔ | Practice format + attendance | `{{}}` | `{{}}` | Open |
| Effectiveness review | — | Option A/B/C | CTO | `{{}}` | Open |
