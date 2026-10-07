# Automation

| Path | Used in | Purpose |
|---|---|---|
| `scripts/dr-env-discover.sh <env> --profile P --region R` | Setup (once per env) | **Builds `env/<env>.env` from what exists** (read-only): account, RDS primary/replica/tags/Multi-AZ, master secret, quarantine SG, evidence bucket, EKS cluster, and the app Secret (namespace, name, host/port/user/password keys; names only, never values). Copies `env/<env>.env.example`, leaves what it cannot find empty with `# TODO`, and lists it. `--print` shows it without writing; `--force` overwrites (keeps `.bak`). Then run `dr-env-check.sh` |
| `scripts/dr-lib.sh` | All | `dr_init <scenario>`, `dr_mark` (timeline), `dr_run` (evidence capture), `dr_set_target`, `dr_dsn` |
| `scripts/dr-preflight.sh replica\|restore` | S2 / S3-S4 Phase 1 | Replica health/lag/LSN, PITR window, snapshots, restore inputs, EKS/ESO/Reloader, consumer inventory |
| `scripts/dr-restore.sh` | S3/S4 | `capture` (source baseline), `plan`, `snapshot`, `pitr` (request built from the baseline, `--cli-input-json`), `wait`, `harden` (converge to baseline), `validate` (all settings), `validate-pg` (pg_settings) |
| `scripts/dr-verify.sh` | S2, CP-02/04 | `wait-promoted`, `db`, `connections` (TARGET vs OLD), `app` |
| `scripts/dr-fence-instance.sh` | CP-04 | `readonly` (F1), `quarantine` (F2), `restore` |
| `scripts/dr-secret-cutover.sh` | **CP-01** | `precheck`, `fix-password`, `apply` (secret → ESO → Reloader wait), `rollback` |
| `scripts/dr-eks-rollout.sh` | CP-01, S1 | `inventory`, `snapshot-generations`, `wait` (verifies the Reloader bump, falls back to a restart), `restart`, `check`, `restart-stale`, `suspend/resume-cronjobs` |
| `scripts/k8s-secret-endpoint.sh` | CP-01 (`SECRET_MODE=k8s`, manual tool) | Standalone: `show`, `history`, `set` (every host key → same endpoint, one patch), `rollback` (undo last), `failback --to <id>`. Ledger ConfigMap `dr-endpoint-ledger-<secret>` records each change ID, old→new per key and old/new DB identifier. Refuses ESO-owned Secrets |
| `scripts/k8s-secret-consumers.sh` | CP-01 (manual tool) | Standalone: `list`, `check` (STALE = pods older than the Secret change), `restart` (only STALE, in restart-order), `restart-one`. `--context` mandatory, `--expect-env` checks the cluster identity |
| `scripts/rds-config-parity.sh [--alarms]` | CP-03 | Config + alarm diff between the old and new instance |
| `scripts/dr-collect-evidence.sh` | CP-05 | CloudTrail/RDS/secret-metadata evidence, KPIs, SHA-256 manifest → S3 Object Lock |
| `scripts/dr-rto-rpo-calc.py` | CP-05 | KPIs per scenario from `timeline.jsonl` |
| `scripts/runbook-to-tracker.py` | Before execution | Generates the sheet tracker (CSV) from any runbook (`--expand` inlines CP steps) |
| `ssm/DR-UpdateDbSecretEndpoint.yaml` | CP-01 (`SECRET_MODE=eso` only) | Secrets Manager host/port/id update, keeping AWSPREVIOUS for rollback. `k8s` mode has no SSM document yet: use `dr-secret-cutover.sh` |
| `ssm/DR-RdsPromoteReplica.yaml` | S2 | Pre-check → G2 → promote → wait standalone → G3 → secret |
| `ssm/DR-RdsRestoreFromSnapshot.yaml` | S3 | Restore (hardened) → wait → G3 → secret |
| `ssm/DR-RdsRestoreToPointInTime.yaml` | S4 | PITR (hardened, `latest` or timestamp, deleted-source aware) → wait → G3 → secret |
| `sql/` | Various | 00 heartbeat · 05 restore-point check · 06 warm-up · 10 replica LSN capture · 15 planned drain · 20 post-recovery verify · 30 reconciliation |
| `k8s/` | Steady state | ExternalSecrets (rw + ro), Reloader Helm values, Deployment conventions, heartbeat writer, Prometheus alerts |

Deploy the SSM documents with IaC (create `DR-UpdateDbSecretEndpoint` first, because the others call it):
```bash
for d in DR-UpdateDbSecretEndpoint DR-RdsPromoteReplica DR-RdsRestoreFromSnapshot DR-RdsRestoreToPointInTime; do
  aws ssm create-document --name "$d" --document-type Automation --document-format YAML --content "file://automation/ssm/$d.yaml"
done
```

**IAM for the executor role (minimum):** `rds:Describe*`, `rds:PromoteReadReplica`, `rds:RestoreDBInstanceFromDBSnapshot`,
`rds:RestoreDBInstanceToPointInTime`, `rds:ModifyDBInstance`, `rds:CreateDBSnapshot`, `rds:CreateDBInstanceReadReplica`,
`rds:AddTagsToResource`, `secretsmanager:GetSecretValue|DescribeSecret|PutSecretValue|UpdateSecretVersionStage|CancelRotateSecret|RotateSecret`
(scoped to `<env>/app/*`), `cloudwatch:GetMetricStatistics|DescribeAlarms`, `cloudtrail:LookupEvents`, `ssm:StartAutomationExecution`,
`s3:PutObject` on the evidence bucket, plus K8s RBAC: get/list/patch on deployments, statefulsets, daemonsets, cronjobs and externalsecrets in the app namespace.

**CI:** `shellcheck -x scripts/*.sh`, `yamllint`, a Python compile check, and `runbook-to-tracker.py` on every runbook (fails if a step table is malformed).
No DR tests are scheduled at present (see [docs/07](../docs/07-testing-and-drill-program.md)). Use `DRY_RUN=1` and the read-only pre-flight to validate scripts against real environments without changing them.
