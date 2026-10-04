# Testing the DR scripts

Two levels. Always run them in this order: **local first**, then **your real AWS account** (DEV/UAT only).

| Level | What | Changes anything real? | Command |
|---|---|---|---|
| 1. Local | k3s + LocalStack + moto + real Postgres + ESO + Reloader + 3 sample apps; 97 end-to-end tests | No (all local containers) | `tests/local/up.sh && tests/local/run-tests.sh` |
| 2a. Real AWS, read-only | Guard, env check, pre-flight, inventory, list snapshots, DRY_RUN restore | **No** | `source env/uat.env && tests/aws/sandbox-test.sh readonly` |
| 2b. Real AWS, sandbox | Restore latest snapshot to a throw-away instance, cutover a **throw-away** secret for 3 sample apps in a **throw-away** namespace, rollback, cleanup | Only throw-away resources (billable instance-hours) | `source env/uat.env && tests/aws/sandbox-test.sh full` |

## 1. Local test bed (`tests/local/`)

```
                   ┌──────────────── k3s cluster (context dr-local) ─────────────────┐
  run-tests.sh     │ ns app (label reloader=enabled)                                 │
  (scripts under   │   ExternalSecret app-db-credentials ──► Secret (POSTGRES_DB_*)  │
   test)           │   app-a  Deployment   reloader annotation ✔  restart-order 2    │
     │             │   app-b  StatefulSet  reloader annotation ✔  restart-order 1    │
     │             │   app-c  Deployment   NO annotation ✘        restart-order 3    │
     │             │   app-report CronJob  (suspend/resume test)                     │
     │             │ ns external-secrets (ESO → LocalStack)   ns reloader (repo values)│
     │             └───────────────────────────────┬────────────────────────────────┘
     │  profile dr-local                           │ pods connect to DB_HOST from the secret
     ├──► LocalStack 172.30.0.10   Secrets Manager, STS, S3 (evidence), SSM, CloudWatch
     ├──► moto 127.0.0.1:5000      RDS + EC2 mock (RDS is a LocalStack Pro feature)
     └──► Postgres containers      "old primary" .21 · "replica" .22 · "restored" .23
          (mock RDS ids → real Postgres via tests/local/.state/endpoint-map, a LOCAL-ONLY seam refused in real envs)
```

The local primary is built from a **sanitised real UAT describe** (`tests/local/fixtures/rds-primary-uat-like.json`: same class,
engine 17.9, gp3 20 GB, 3 SGs, 3 subnets in 2 AZs, parameter group, windows, monitoring, PI, CloudFormation `aws:*` tags) via the
same request builder the DR scripts use. Use another instance's shape: `RDS_FIXTURE=/path/describe-object.json tests/local/up.sh`
(one `DBInstances[0]` object — sanitise account ids/ARNs first).

Requirements: Docker, `kubectl`, `helm`, `aws` CLI, `psql`, `jq`, Python 3 with `moto[server]` (`pip install "moto[server]"`).

```bash
tests/local/up.sh                 # k3s in Docker (default). Or bring your own cluster:
K3S_MODE=existing EXISTING_KUBECONFIG=~/.kube/k3d-dr.yaml tests/local/up.sh
tests/local/run-tests.sh          # report: tests/local/.state/test-report.md · logs: .state/logs/
tests/local/down.sh               # remove everything (K3S_MODE=existing: only what up.sh installed)
```

Safety of the test bed itself (it installs Helm releases, namespaces and a ConfigMap):
- `up.sh` **refuses** unless the cluster API server is local (`127.x`, `localhost`, `::1`, `0.0.0.0`, `kubernetes.docker.internal`) — checked
  before anything is created — and the cluster has no `kube-system/dr-cluster-identity` or one saying `env=local`.
- `down.sh` (`K3S_MODE=existing`) **refuses** unless the API server is local **and** the identity says `env=local`; nothing is removed otherwise.
  Docker cleanup only touches the `drtest-*` containers/volume/network that `up.sh` created.

What is covered:

| Group | Tests |
|---|---|
| A. Guardrails | Pinned profile passes; **authentication kinds** (static key in a named profile and SSO both detected; `DR_AUTH_ALLOWED=sso,role` refuses a key; expired SSO names the exact `aws sso login` command; unknown profile refused; a rejected key says it is not an SSO profile); wrong-account profile refused; unknown and decoy contexts refused; cluster identity mismatch refused; local seam refused outside local; PROD confirmation blocks non-interactive runs; **strict pinning**: `aws` without `--profile/--region` → 97, `--profile dr-decoy` → 97 (even with `DR_STRICT_PIN=0`), `kubectl` without/with decoy `--context` → 97; `[default]` profile, kube `current-context`, a `dr-prod` context in the kubeconfig, exported keys → refused; pinning lint; fill-in mode ignores a decoy current-context |
| B. Checks | `dr-env-check.sh`, inventory (**app-c flagged `reloader=NO`**), pre-flight restore + replica |
| C. S3 restore | **baseline capture** of the source (describe + 4 tags incl. a value with spaces + `pg_settings`), `plan` (request has 3 SGs, subnets, PG, retention 7, backup window, log exports, tags; nothing created), restore with `--cli-input-json`, wait, `validate` **fails** before harden (maintenance window), simulated CLI-default **retention 1 day + lost tag → detected**, `harden` → **VALIDATED**, password trap (precheck fails → `fix-password`), `validate-pg` equal + detects a changed `work_mem`, row counts, DB verification SQL |
| D. Cutover | `apply` with `RESTART_UNANNOTATED=false`: secret → ESO → **Reloader restarts app-a + app-b**; **app-c untouched** (same pod, same generation) and still connected to the old DB; standalone **`k8s-secret-consumers.sh`**: refuses without `--context` / wrong env, `check` shows **app-c STALE** and app-a/app-b UP-TO-DATE, `restart-stale` restarts **only app-c** (app-a/app-b generation unchanged), `check` clean afterwards; `rollback`/`apply` with `RESTART_UNANNOTATED=true`: app-c restarted by the script; session checks in Postgres |
| E. Fencing | F1 read-only + F2 quarantine SG + un-fence; CronJob suspend/resume |
| F. S2 / S4 | promote replica + `wait-promoted`; PITR `latest` from the baseline, harden → VALIDATED |
| G. Evidence | **recorded session** `dr-session.sh` (transcript + history, password redacted, refusal visible, synced to S3), **`commands.jsonl` audit** (secret-string redacted, refusals logged), phase timers + **sync at phase end**, evidence bundle uploaded (S3), KPI report (RPO from snapshot time), SSM documents accepted, tracker for every runbook |
| H. `SECRET_MODE=k8s` | plain Secret `app-db-direct` with **two host keys** (`POSTGRES_DB_HOST1` → app-d, annotated; `POSTGRES_DB_HOST2` → app-e, not annotated): show; refuses an ESO-owned Secret and a bad ID; pre-flight; cutover #1 → **both keys** = restored + annotations; ledger entry (id, old→new per key, old/new DB id); Reloader restarts app-d, app-e reported then restarted by `restart-stale`; **Reloader alert webhook received**; cutover #2 → replica; **`failback <id of #1>`** → both keys + both apps back on the old primary; `history` shows 3 entries; `rollback` undoes the failback; rollback refused when the Secret was changed outside the ledger |
| I. UAT-shaped requests | offline from the sanitised UAT describe (`tests/local/fixtures/rds-primary-uat-like.json`): restore request (3 SGs, subnet group, PG, no default option group, **no gp3 IOPS < 400 GB**, port 5432 not `DbInstancePort` 0, lifecycle/backup target/license, **no `aws:*` tags**); harden request (maintenance window, Enhanced Monitoring + role, PI + KMS + retention, Database Insights, retention 1→7); create-like request; validate ignores identity fields + `UpgradeRolloutOrder`; **create-like round trip** on the mock → harden → VALIDATED |

Mock limitations (documented, not hidden): moto keeps the replica link after promotion (patched in `moto_launcher.py`, the mock is fixed, not the scripts); no real replication lag/WAL; CloudTrail lookups return nothing; SSM documents are stored but not executed.

### Notes for constrained hosts (how it was run in a cloud sandbox)
- If pods fail with `runc … can't get final child's PID`, the kernel forbids negative `oom_score_adj`. Run k3s natively with a containerd template that sets `restrict_oom_score_adj = true`, then use `K3S_MODE=existing`.
- Docker ≥ 28 drops pod → container traffic ("direct routing protection"). `up.sh` creates the test network with `gateway_mode_ipv4=nat-unprotected` and adds `DOCKER-USER` / raw-table accept rules for `10.42.0.0/16 ↔ 172.30.0.0/24`.
- Behind an HTTP proxy, add the node IP to `NO_PROXY` for k3s, or `kubectl logs/exec` break.

### Running on macOS
- **The DR scripts themselves** (real AWS from a Mac) work with the Homebrew tools: `brew install bash coreutils jq libpq awscli kubectl helm`.
  `dr-lib.sh` puts GNU coreutils/libpq on `PATH` automatically and stops with a clear error if bash < 4 or GNU `date` is missing.
- **The local test bed (`up.sh`)** needs a Linux Docker host: it runs k3s with `--network host`, talks to container IPs
  (172.30.0.x) from the host and adds iptables rules — none of that exists on the Mac side of Docker Desktop.
  Run it inside a Linux VM on the Mac (same scripts, no changes), e.g.:
  ```bash
  brew install orbstack && orb create ubuntu drtest && orb -m drtest        # or: limactl start / colima ssh / multipass
  # inside the VM: install docker, kubectl, helm, awscli, jq, postgresql-client, python3-venv + moto[server]
  cd /path/to/repo && tests/local/up.sh && tests/local/run-tests.sh
  ```

## 2. Real AWS (`tests/aws/sandbox-test.sh`)

### Your env file (`env/uat.env`) — on YOUR machine only
`env/<env>.env` is **not in Git** (`.gitignore`: `env/*.env`) — it holds account IDs, instance names, role patterns. Create
it in your own clone, from the example:
```bash
cd ~/src/Disaster-Recovery-DR-framework-and-actionable-Runbook-optimization     # your clone on the Mac
cp env/uat.env.example env/uat.env && $EDITOR env/uat.env
```
Fill in at least: `ACCOUNT_ID`, `AWS_PROFILE` (your SSO profile), `AWS_ROLE_PATTERN='assumed-role/AWSReservedSSO_lab_admin_'`,
`AWS_REGION`, `KUBECONFIG`, `EKS_CONTEXT`, `EKS_CLUSTER_NAME`, `PRIMARY_DB`, `REPLICA_DB`, `DB_NAME`, `K8S_NS`,
`SECRET_MODE=k8s`, `K8S_SECRET`, `K8S_HOST_KEY=POSTGRES_DB_HOST1,POSTGRES_DB_HOST2`, `K8S_PORT_KEY`, `K8S_USER_KEY`,
`K8S_PASSWORD_KEY`, `MASTER_SECRET_ID` (password fix / fencing), `EVIDENCE_BUCKET`. With `SECRET_MODE=k8s`, `SECRET_ID` is not needed.

### Running — step by step, with live output
```bash
aws sso login --profile dr-uat && source env/uat.env
tests/aws/sandbox-test.sh --list                   # all steps (R01…R13 read-only, W01…W22 sandbox) + their prerequisites
tests/aws/sandbox-test.sh readonly                 # every step shows its output live (indented); -q for ✅/❌ only
tests/aws/sandbox-test.sh readonly --only R01,R02  # just these steps
tests/aws/sandbox-test.sh readonly --skip R03      # all but these
tests/aws/sandbox-test.sh full                     # R + W (asks you to type 'sandbox' before creating anything)
tests/aws/sandbox-test.sh full --keep              # keep the sandbox at the end (or after an abort) …
SB_TS=<ts> tests/aws/sandbox-test.sh full --from W12 --keep   # … fix the cause, resume from a step with the same names
SB_TS=<ts> tests/aws/sandbox-test.sh cleanup       # … and remove it when done
```
Reports: `tests/aws/reports/sandbox-report-<env>-<ts>.md` (table per step, PASS/FAIL/blocked, duration, measured restore
time) and `….md.log` (full output of every step). Local only (git-ignored) — they contain account details.

**When a step fails** (`--on-fail`):
| Mode | Default when | Behaviour |
|---|---|---|
| `ask` | running in a terminal | `[r]etry` (fix something in another terminal, then retry) · `[s]kip` (count as failed, go on) · `[a]bort` (stop; cleanup runs unless `--keep`) |
| `stop` | `full` without a terminal (CI) | stop at the first failure; cleanup runs |
| `continue` | `readonly` without a terminal | record and go on (safe: read-only) |

**Prerequisites are enforced in every mode:** a step whose prerequisite failed is **BLOCKED** and never runs (`--list`
shows them). Example from the local rehearsal: W10 (app password on the restored DB) failed → W11 validate-pg, W12 cutover,
W13 and W20 were blocked; the sandbox was still cleaned up. So a failed restore, harden/validate or password check can never
be followed by a cutover. And all W steps act only on the throw-away namespace and instance — never on your app Secret,
app namespace, primary or replica.

Rehearsed locally in your exact configuration (SECRET_MODE=k8s, two host keys, no SECRET_ID):
`SANDBOX_ALLOW_LOCAL=1 SECRET_MODE=k8s K8S_SECRET=app-db-direct K8S_HOST_KEY=POSTGRES_DB_HOST1,POSTGRES_DB_HOST2 DRTEST_PGSSLMODE=disable tests/aws/sandbox-test.sh full`
(after `source tests/local/.state/local.env`) → 33/33 PASS. `SANDBOX_ALLOW_LOCAL` is honoured only with `DR_ENV=local`.

Before running:
1. Log in with your SSO profile (`aws sso login --profile dr-uat` — or just start the script: if the session expired it offers the login, waits for the browser, and continues). A static key in a **named** profile also works for UAT/DEV (not PROD): see [docs/12](../docs/12-account-and-cluster-safety.md). Set `AWS_ROLE_PATTERN` to your role (a regex, e.g. `assumed-role/AWSReservedSSO_lab_admin_`) so the guard accepts it and nothing else.
2. Set up isolation and pinning per [docs/12](../docs/12-account-and-cluster-safety.md): named profile, separate kubeconfig (no current-context), `kube-system/dr-cluster-identity` ConfigMap, `env/<env>.env`.
3. `readonly` first; it must be all green.
4. For `full`: Reloader installed, the sample image pullable (`DRTEST_IMAGE`, default `postgres:16-alpine`), EKS → DB network access (the restored instance gets the same SGs as the primary). `SECRET_MODE=eso` only: an ESO store that can read `<env>/dr-test/*` (`DRTEST_STORE_KIND`/`DRTEST_STORE_NAME`).

Safety properties of `full`:
- Refuses `DR_ENV=prod`; asks you to type `sandbox`.
- Never writes to your app Secret, the app namespace, the primary or the replica. It reads the app Secret once to copy the credentials into the sandbox namespace.
- Cleanup on exit always deletes the sandbox namespace (incl. its Secret and ledger), the Secrets Manager copy (eso mode) and the restored instance (deletion protection removed first), even on failure or Ctrl-C — unless `--keep`.
- The report includes the **measured snapshot-restore time** (input for risk R3 / the 30 min RTO).
