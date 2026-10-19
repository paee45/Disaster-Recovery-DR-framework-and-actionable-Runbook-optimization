# Automation

## SQL-free operator recovery

The S3/S4 runner defaults to `DR_DB_ACCESS=none`. It requires `SECRET_MODE=k8s` and an endpoint-only Secret
(host/port, no credentials). In this mode it runs no SQL, fetches or caches no database passwords, and never runs
`fix-password`. `DR_DB_ACCESS=readonly` is a separate, explicitly selected legacy workflow, not the operator default;
ESO and the SQL/password tools listed below are not part of SQL-free recovery.

- Only `FENCE=stop` is accepted by the runner in `none` mode. Confirm the old DB is stopped before E2E/T9;
  SQL read-only fencing, quarantine and skip are not accepted substitutes. S4 supports full cutover (mode A), not surgical repair.
- RDS API availability/configuration and endpoint/consumer/Reloader checks prove only those checks passed. They do not
  prove database login, application connectivity, committed business writes or data correctness.
- Record `DATA_OWNER` and `DATA_ACCEPTANCE_REF` for acceptance of the restore point/loss window; S4 also needs
  `RESTORE_POINT_REF`. Before T9, the application owner supplies `APP_OWNER`, `APP_DB_DESTINATION` matching the restored
  DB, and `E2E_REF` proving connectivity and a successful business transaction there. The E2E gate needs typed GO and
  an approver matching `APP_OWNER`. Do not replace owner evidence with an API success or an operator SQL probe.

### Local migration (pending)

New Terraform `direct_only` configuration splits `app-db-endpoint` (host/port) from credential Secret `app-db-direct`.
Both app-d/app-e consume the split configuration and are annotated for Reloader on `app-db-endpoint`.
The `dr-operator` ServiceAccount can get/patch only the named endpoint Secret, with ledger and read-only inventory
access. It cannot read credential Secrets, list Secrets, exec into pods or mutate workloads.

After the owner reviews and approves a saved workloads plan and that exact plan is applied, the privileged app/platform
owner runs `bash iac/local/prepare-operator.sh` **inside drtest-tools**. It writes
`tests/local/.state/operator-kubeconfig` with a requested four-hour token without printing it, checks endpoint access,
and runs negative authorization tests for credential reads, Secret listing, pod exec and workload mutation.
Local `iac/local/dr.sh` requires this kubeconfig in `none` mode; renew it through the same privileged setup when needed.
Host/platform provisioning and host DB lifecycle actions remain privileged. This is not isolation from a person who
can use the host admin kubeconfig or control the tools container.

Status (2026-10-19): code/offline checks only; the split configuration has **not** been applied or drilled. Old DB is
running, restored DB is stopped, and apps still use `.21` through the legacy mixed Secret. Next: saved-plan approval,
migration and operator-token preparation, then new restore/failback drills with data-owner acceptance and user-driven
application E2E/GO gates. Endpoint failback does not copy restored-side writes; reconcile first or explicitly accept
disposable local test-data loss. The app owner must verify the failback destination and business E2E before declaring recovery.
Real AWS operations remain paused. Historical SQL drills/evidence are unchanged and are not SQL-free proof;
local/mock RTO/RPO values are not AWS performance measurements.

| Path | Used in | Purpose |
|---|---|---|
| `scripts/dr-env-discover.sh <env> --profile P --region R` | Setup (once per env) | **Builds `env/<env>.env` from metadata** (read-only): account, RDS primary/replica/tags/Multi-AZ, Secret identifiers, quarantine SG, evidence bucket and EKS cluster. It never calls `GetSecretValue` or fetches Kubernetes Secret payloads. Supply the endpoint-only Secret namespace/name through `--namespace`/`--secret` and review host/port key names from application configuration. Templates containing password assignments are refused; key names/Secret IDs are references, not password values. `--print` previews; `--force` overwrites with `.bak`. Then run `dr-env-check.sh` |
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

**Legacy/privileged executor permissions (not the SQL-free operator role):** `rds:Describe*`, `rds:PromoteReadReplica`, `rds:RestoreDBInstanceFromDBSnapshot`,
`rds:RestoreDBInstanceToPointInTime`, `rds:ModifyDBInstance`, `rds:CreateDBSnapshot`, `rds:CreateDBInstanceReadReplica`,
`rds:AddTagsToResource`, `secretsmanager:GetSecretValue|DescribeSecret|PutSecretValue|UpdateSecretVersionStage|CancelRotateSecret|RotateSecret`
(scoped to `<env>/app/*`), `cloudwatch:GetMetricStatistics|DescribeAlarms`, `cloudtrail:LookupEvents`, `ssm:StartAutomationExecution`,
`s3:PutObject` on the evidence bucket, plus K8s RBAC: get/list/patch on deployments, statefulsets, daemonsets, cronjobs and externalsecrets in the app namespace.

**CI:** `shellcheck -x scripts/*.sh`, `yamllint`, a Python compile check, and `runbook-to-tracker.py` on every runbook (fails if a step table is malformed).
No DR tests are scheduled at present (see [docs/07](../docs/07-testing-and-drill-program.md)). Use `DRY_RUN=1` and the read-only pre-flight to validate scripts against real environments without changing them.
