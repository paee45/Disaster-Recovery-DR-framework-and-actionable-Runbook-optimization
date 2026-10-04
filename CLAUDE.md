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

## Key entry points
| Need | Use |
|---|---|
| Run a restore step by step (live output, evidence per step, gates, resume) | `automation/scripts/dr-run.sh S3\|S4` (`--list`, `--dry-run`, `--to P2-S05`, `--resume <DR_ID>`) |
| Recorded manual shell | `automation/scripts/dr-session.sh env/<env>.env <SCENARIO>` |
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
- Latest suite: v0.6 (109 tests, group J = dr-run.sh): full run 107/109 — J02/J09 were test bugs (grep -q SIGPIPE; `env -u` order), fixed and passing; clean re-run pending.
- In tests never use `grep -q` after a pipe under `pipefail` (SIGPIPE → false failure); `env` options (`-u X`) go before assignments.
- **Next for the owner (on the Mac, UAT):** `cp env/uat.env.example env/uat.env`, fill values, `PRIMARY_STOPPED_OK=1`,
  `REPLICA_DB=""`, `source env/uat.env`, then `tests/aws/sandbox-test.sh readonly`, then
  `automation/scripts/dr-run.sh S3 --dry-run` and `--to P2-S05` (restore + verify, no cutover).
- Open to-dos: see README "To-do / improvements" (ESO adoption, …).
