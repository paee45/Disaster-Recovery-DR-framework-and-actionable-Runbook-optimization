# Testing the DR scripts

Two levels. Always run them in this order: **local first**, then **your real AWS account** (DEV/UAT only).

| Level | What | Changes anything real? | Command |
|---|---|---|---|
| 1. Local | k3s + LocalStack + moto + real Postgres + ESO + Reloader + 3 sample apps; ~75 end-to-end tests | No (all local containers) | `tests/local/up.sh && tests/local/run-tests.sh` |
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
| A. Guardrails | Pinned profile passes; wrong-account profile refused; unknown and decoy contexts refused; cluster identity mismatch refused; local seam refused outside local; PROD confirmation blocks non-interactive runs; **strict pinning**: `aws` without `--profile/--region` → 97, `--profile dr-decoy` → 97 (even with `DR_STRICT_PIN=0`), `kubectl` without/with decoy `--context` → 97; `[default]` profile, kube `current-context`, a `dr-prod` context in the kubeconfig, exported keys → refused; pinning lint; fill-in mode ignores a decoy current-context |
| B. Checks | `dr-env-check.sh`, inventory (**app-c flagged `reloader=NO`**), pre-flight restore + replica |
| C. S3 restore | **baseline capture** of the source (describe + 4 tags incl. a value with spaces + `pg_settings`), `plan` (request has 3 SGs, subnets, PG, retention 7, backup window, log exports, tags; nothing created), restore with `--cli-input-json`, wait, `validate` **fails** before harden (maintenance window), simulated CLI-default **retention 1 day + lost tag → detected**, `harden` → **VALIDATED**, password trap (precheck fails → `fix-password`), `validate-pg` equal + detects a changed `work_mem`, row counts, DB verification SQL |
| D. Cutover | `apply` with `RESTART_UNANNOTATED=false`: secret → ESO → **Reloader restarts app-a + app-b**; **app-c untouched** (same pod, same generation) and still connected to the old DB; standalone **`k8s-secret-consumers.sh`**: refuses without `--context` / wrong env, `check` shows **app-c STALE** and app-a/app-b UP-TO-DATE, `restart-stale` restarts **only app-c** (app-a/app-b generation unchanged), `check` clean afterwards; `rollback`/`apply` with `RESTART_UNANNOTATED=true`: app-c restarted by the script; session checks in Postgres |
| E. Fencing | F1 read-only + F2 quarantine SG + un-fence; CronJob suspend/resume |
| F. S2 / S4 | promote replica + `wait-promoted`; PITR `latest` from the baseline, harden → VALIDATED |
| G. Evidence | **recorded session** `dr-session.sh` (transcript + history, password redacted, refusal visible, synced to S3), **`commands.jsonl` audit** (secret-string redacted, refusals logged), phase timers + **sync at phase end**, evidence bundle uploaded (S3), KPI report (RPO from snapshot time), SSM documents accepted, tracker for every runbook |

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

Before running:
1. Log in with your SSO profile (`aws sso login --profile dr-uat`); set `AWS_ROLE_PATTERN` to your role (a regex, e.g. `assumed-role/AWSReservedSSO_lab_admin_`) so the guard accepts it and nothing else.
1. Set up isolation and pinning per [docs/12](../docs/12-account-and-cluster-safety.md): named profile, separate kubeconfig, `kube-system/dr-cluster-identity` ConfigMap, `env/<env>.env`.
2. `readonly` first; it must be all green.
3. For `full`: an ESO store that can read `<env>/dr-test/*` (`DRTEST_STORE_KIND`/`DRTEST_STORE_NAME`), Reloader installed, the sample image pullable (`DRTEST_IMAGE`), and EKS → DB network access (the restored instance gets the same SGs as the primary).

Safety properties of `full`:
- Refuses `DR_ENV=prod`; asks you to type `sandbox`.
- Never writes to `$SECRET_ID`, the app namespace, the primary or the replica. It reads the app secret once to copy the credentials.
- `trap cleanup EXIT` always deletes the namespace, the secret (force delete) and the restored instance (deletion protection removed first), even on failure or Ctrl-C.
- Writes a report `tests/aws/sandbox-report-<env>-<ts>.md`, including the **measured snapshot-restore time** (input for risk R3 / the 30 min RTO).
