# CLAUDE.md — working notes for AI assistants (and humans) continuing this repo

Read this first. Keep it current: update it in the same commit as any change that alters a rule, decision or status below.

## What this is
Capstone: enterprise DR framework + runbooks for **AWS RDS PostgreSQL + EKS apps**. Recovery = write the new DB endpoint
into the app's secret → **Reloader** restarts the pods (no DNS change). Envs dev / uat / prod, scenarios S1–S4 + failbacks,
ISO 27001 scope, **RPO 24 h, RTO 30 min**. Start with `README.md` and `runbooks/README.md`.

## Hard rules
- **Never commit real AWS account IDs, ARNs, instance/SG/subnet IDs or hostnames of the owner's accounts.** Only the
  sanitised fixture `tests/local/fixtures/rds-primary-uat-like.json` and placeholders (`{{…}}`, `000000000000`).
  `env/*.env` (real values) is git-ignored; only `env/*.env.example` is committed.
- Branch: `claude/enterprise-dr-rds-runbook-ksy0q8`. Commit + push there. **No pull request unless the owner asks.**
- No model names/IDs in commits, code or docs.
- Every `aws` call carries `--profile "$AWS_PROFILE" --region "$AWS_REGION"`, every `kubectl` call `--context "$EKS_CONTEXT"`
  (strict pinning; unpinned calls exit 97). `tests/lint/pinning-lint.sh` + `shellcheck -S warning -x -P automation/scripts …`
  must pass (CI: `.github/workflows/dr-lint.yml`, hook: `.githooks/pre-commit`).
- Code style: bash, `set -o pipefail`, comment density like the existing scripts, plain English in docs (non-native readers).

## Owner decisions (do not re-litigate)
- **`SECRET_MODE=k8s`** (plain Kubernetes Secret patched directly, every key in `K8S_HOST_KEY`, e.g.
  `POSTGRES_DB_HOST1,POSTGRES_DB_HOST2`, gets the same endpoint; each change recorded with an ID in the ledger ConfigMap
  `dr-endpoint-ledger-<secret>`; `failback <id>` / `rollback`). **ESO (`SECRET_MODE=eso`) is a to-do**, kept working.
- Reloader has no UI: notification = Reloader alert webhook + Prometheus rules (`automation/k8s/`).
- UAT primary is **intentionally stopped** → `PRIMARY_STOPPED_OK=1` in `env/uat.env` (INFO, not WARN). UAT replica may be unset.
- Login: SSO (browser login, the scripts wait and continue) or static key. `DR_AUTH_ALLOWED`: dev/uat `sso,role,key`, prod `sso,role`.
- Restore is **baseline-driven** (`dr-restore.sh capture/plan/snapshot/pitr/wait/harden/validate/validate-pg`,
  request builders in `automation/scripts/rds-requests.jq`); backup retention floor 7; validate every setting.
- Owner works on **macOS** (brew bash/coreutils/jq/libpq/awscli/kubectl); the real-AWS tests run on the Mac, not in a cloud container.

## Lab on real AWS (owner decision)
- Real UAT is in another account the owner's SSO cannot reach; no profile of a real account may be used for the lab.
- Tests on real AWS run in the owner's **sandbox account** via SSO profile `lab_sandbox` (region ap-southeast-1),
  built with **Terraform only** (stacks `iac/lab/{network,eks,addons,db,app}`, run with `iac/tf.sh`; anything reusable
  lives in git/IaC, no ad-hoc shell builders). dev/uat/prod all play in the sandbox: one shared VPC + EKS, `db` and `app`
  once per env. Small/free-tier sizes: RDS `db.t4g.micro`, EKS node `t3.small` (t3.micro cannot fit the pods).
  Destroy or pause after each session (EKS is ~0.10 USD/h). **Terraform state is in S3** (bucket per account, key
  `<project>/<env|shared>/<component>/terraform.tfstate`, native locking); layout in `iac/README.md`.
  Always plan to a file, show it to the owner, then apply that file (owner asked for this; no `-auto-approve`).
- Terraform UI = **Terrakube on one EC2 `t4g.small`** (owner choice: cheap, with swap + JVM caps; `t4g.medium` if too
  slow; t4g.micro is too small) — `iac/platform/terrakube`. No inbound ports: SSM port-forward + mkcert + /etc/hosts
  `*.platform.local`. Built BEFORE the DR lab (owner choice). Instance role AdministratorAccess (sandbox only) so
  Terrakube can run the lab stacks (`aws_profile` empty → instance role; k8s auth by token).

## Key entry points
| Need | Use |
|---|---|
| Build `env/<env>.env` from what exists in AWS/the cluster (no manual lookups) | `automation/scripts/dr-env-discover.sh <env> --profile P --region R` (then `dr-env-check.sh`) |
| Run a restore step by step (live output, evidence per step, gates, resume) | `automation/scripts/dr-run.sh S3\|S4` (`--list`, `--dry-run`, `--to P2-S05`, `--resume <DR_ID>`) |
| Recorded manual shell | `automation/scripts/dr-session.sh env/<env>.env <SCENARIO>` |
| Run any Terraform stack (state in S3, plan/apply, stop/start DB) | `iac/tf.sh <stack> [env] <cmd>`, guide `iac/README.md` |
| Build / destroy the sandbox lab (Terraform) | `iac/lab/README.md` |
| Terraform UI for the sandbox (Terrakube on EC2) | `iac/platform/terrakube/README.md`, config as code `iac/platform/terrakube-config` |
| Safe test against real AWS (dev/uat only) | `tests/aws/sandbox-test.sh readonly` then `full` |
| Local end-to-end tests | `tests/local/up.sh && tests/local/run-tests.sh` (report `tests/local/.state/test-report.md`) |
| Secret endpoint / consumers tools | `k8s-secret-endpoint.sh`, `k8s-secret-consumers.sh`, `dr-secret-cutover.sh`, `dr-eks-rollout.sh` |

## Local test bed in a cloud container (Linux)
- Needs dockerd running and **native k3s**: if down, start dockerd, then `/tmp/start-k3s.sh` (container-local helper; recreate if
  missing: k3s server with a containerd template setting `restrict_oom_score_adj = true`).
- Always: `K3S_MODE=existing EXISTING_KUBECONFIG=/etc/rancher/k3s/k3s.yaml`, and `unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN`
  (strict mode refuses exported keys). Default `K3S_MODE=docker` does NOT work in the cloud container.
- Clean run: `tests/local/down.sh && tests/local/up.sh && tests/local/run-tests.sh` (~15–20 min). Do not edit
  `run-tests.sh` while it runs (bash reads scripts incrementally).
- `pkill -f <pattern>` can kill your own shell if the pattern is in the command line — use `pgrep` + `kill <pid>`.
- Run only ONE build at a time (overlapping up.sh runs break each other); a wrapper script avoids self-matching kills.

## Status (update as you go)
- Latest suite: v0.6 = **109/109** (clean Terraform-managed fixture, 2026-10-13; report `tests/local/.state/test-report.md`). Group J = dr-run.sh.
- In tests never use `grep -q` after a pipe under `pipefail` (SIGPIPE → false failure); `env` options (`-u X`) go before assignments.
- Owner's Mac is set up (repo at `~/dr-framework`, brew bash 5 / coreutils / libpq / awscli / kubectl); `claude` CLI not installed.
  zsh: paste blocks without inline `#` comments (or `setopt interactivecomments`).
- **Done (2026-10-09):** Terrakube runs on `t4g.medium` (resized in place; `user_data` is ignored so the instance and its
  Postgres are never replaced by accident), MinIO removed, storage on the real S3 bucket with the instance role. Terrakube
  replaces the code's `backend "s3"`, so state sharing relies on `TF_CLI_ARGS_init` (set in `terrakube-config`): UI and
  `tf.sh` use the same S3 key (proved with `lab-network`). Built in the sandbox: `lab/network`, `lab/db uat`, `lab/eks`
  (cluster `dr-lab-eks`, SSO admin access entry with the full SSO role ARN), `env/uat.env` from `dr-env-discover.sh`.
  `iac/lab/destroy-all.sh` = ordered, confirmed destroy of what is deployed.
- **Gotchas:** operator IP changes -> re-apply `lab/db <env>` and `terrakube-config` (`operator_cidr`). The EKS creator is the
  only admin, so a cluster built from the UI needs the SSO access entry (in `eks.tf`). kubeconfig files are written where
  the apply runs: after a UI apply of `lab-eks`, run `tf.sh lab/eks plan/apply` on the Mac for the 3 local files.
- **Local migration (2026-10-13):** Terraform stages in `iac/local/{platform,mock,addons,workloads}` and `iac/local.sh`
  replace ad-hoc setup for the isolated runner. Dedicated Colima profile `dr-framework`; old default profile stopped,
  data preserved. Platform state is per Docker context; no host AWS/kube credentials or real env files mounted. The
  no-ESO direct-secret S3 walkthrough passed through P2-S05, cutover, E2E reference, evidence collection, and endpoint
  failback; both app sessions returned to `app-pg-local`. RTO/RPO are local-mock measurements, not AWS performance.
  The legacy full regression suite (ESO opt-in) passed 109/109 on 2026-10-13. Local direct-secret S4 `DR-20261013-1437-local-S4`
  completed after reconciling the restored DB password from the local Kubernetes Secret; the app now targets the restored DB
  and the old DB is fenced read-only. At initial run close, RTO was 44.66 min (target 30) and RPO 2,640.5 s (target 24 h).
  The refreshed post-reconciliation report says RPO 3,260.7 s because the KPI calculator uses the latest `FENCE` marker,
  including the post-run synthetic re-fence; use 2,640.5 s for the original S4 run measurement. The RTO
  includes about 30.7 min between the initial P2-S03 failure and resuming the run, largely while the operator was away from
  the Mac; the local password mismatch was fixed on resumption. This elapsed pause was counted as app recovery, not intrinsic
  restore time. Moto had no automated-backup PITR window, so the local restore timestamp was simulated.
  Initial read-only hints found no `created_at` rows after the cutoff. A separate synthetic local P3A-S06 exercise inserted
  `public.orders` id 101 after the cutoff on the old DB, detected it, copied it transactionally to the restored DB, and
  verified the matching row; the old DB was re-fenced read-only. This is a test only, not business-data reconciliation or
  sign-off. Actual production P3A-S06 remains pending; keep the old DB fenced and do not fail back until owner review.
  Do not treat these values as AWS performance or change production targets from them. Evidence:
  `tests/local/.state/evidence/DR-20261013-1437-local-S4/`. Do not run `tests/local/up.sh` or `down.sh` against Terraform-owned
  containers.
- **Local walkthrough:** no ESO by default (`enable_eso=false`, `direct_only=true`): plain `app-db-direct`, app-d/app-e,
  Reloader, and endpoint ledger. The legacy full regression suite needs an explicit ESO opt-in and a clean fixture.
- **Mock fidelity:** Moto 5.0.28 is patched for unique DB resource IDs, replica isolation, and RDS field round-trips.
  `app-pg-local-fixture` is a Terraform-owned manual mock snapshot; it is not a scheduled backup or a real data clone.
  The mock also has synthetic automated snapshot metadata (`app-pg-local-daily-1d`, `app-pg-local-daily-2d`) and
  discovery-only RDS primaries (`local-dev-db`, `orders-primary-01`, `local-uat-db`, `local-prod-db`). These have no
  corresponding app databases and are never DR targets. Discovery matches `Environment`/`env` tags, not identifier names;
  DEV intentionally exercises ambiguous tagged discovery (`--db` is required without a TTY).
- **Gotcha:** stopping the Colima VM clears moto/LocalStack in-memory state while preserving Postgres and k3s volumes.
  Reapply the mock Terraform stage before resuming a DR run; this creates the mock snapshot and Secrets Manager records.
- **Next:** production P3A-S06 reconciliation/sign-off remains pending, then P3A-S07. Local DEV P1-S03 adoption is complete
  through `iac/local/normalization`; DEV has no replica. Keep real-AWS operations paused; local work does not stop any
  existing AWS billing.
- Open to-dos: see README "To-do / improvements" (ESO adoption, …).
