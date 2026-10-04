# CP-01 — Secret Endpoint Cutover (Secrets Manager → ESO → Reloader)

**Used by:** S2, S3, S4 (all envs), and FB runbooks that change the instance identifier. **Not used by S1** (the Multi-AZ endpoint does not change).
**Automation:** `automation/scripts/dr-secret-cutover.sh` or SSM `DR-UpdateDbSecretEndpoint`.
**Budget:** 10 min (PROD), up to the slowest Deployment's rollout time.

## How the chain works

```
 put-secret-value (host=<TARGET_DB endpoint>)          Secrets Manager: new version = AWSCURRENT
        │                                               (previous version auto-labelled AWSPREVIOUS → rollback)
        ▼
 ExternalSecret db-creds  (refreshInterval 1m, or force-sync annotation = immediate)
        │  writes K8s Secret db-creds (data hash changes)
        ▼
 Stakater Reloader  (annotation secret.reloader.stakater.com/reload: "db-creds")
        │  rolling restart of every annotated Deployment/StatefulSet/DaemonSet
        ▼
 New pods read DB_HOST from the Secret → connect to TARGET_DB
        │
        ▼
 Old pods terminate → their connections to OLD_DB close → verify OLD_DB has 0 app sessions (CP-02)
```

**What Reloader does NOT cover. Handle these explicitly:**
| Workload | Behaviour | Action |
|---|---|---|
| CronJobs | Each run creates new pods, which read the new Secret | Suspend during the event; resume after CP-02 |
| Running Jobs (migrations, batch) | Keep the old endpoint until they finish | Delete/restart them after cutover |
| Workloads without the annotation | Not restarted | The pre-flight lists all Secret consumers without the annotation (step S01) |
| Apps that read the secret **directly from Secrets Manager** (SDK, not the K8s Secret) | Not restarted, and may cache | Restart manually (`kubectl rollout restart`) or check the app's cache TTL |
| Connection poolers (PgBouncer) | They hold the upstream host | Annotate them too, with `restart-order 1` |

## Steps

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| CP01-S01 | **Inventory consumers**: `./automation/scripts/dr-eks-rollout.sh inventory` lists every workload that mounts/env-refs `$K8S_SECRET`, with or without a Reloader annotation | Executor | 1 | No unannotated consumers, or the list is noted for manual restart |
| CP01-S02 | **Suspend secret rotation** (a rotation run would race with the cutover): `aws secretsmanager cancel-rotate-secret --secret-id $SECRET_ID` (only if `RotationEnabled=true`; record this so rotation is re-enabled in CP-03) | Executor | 1 | `RotationEnabled=false` |
| CP01-S03 | **Suspend CronJobs** that use the DB: `./automation/scripts/dr-eks-rollout.sh suspend-cronjobs` | Executor | 1 | Listed CronJobs `suspend=true` |
| CP01-S04 | **Pre-verify credentials on TARGET_DB *before* switching**: `./automation/scripts/dr-secret-cutover.sh precheck`. ⚠ **S3/S4 trap:** a restored DB holds passwords **as of the restore point**. If the app password was rotated since then, the current secret password fails. The script reports this, and `fix-password` resets the role password on TARGET_DB to the current secret value (needs the master credentials) | DBA | 3 | `login OK as $APP_DB_USER on TARGET_DB`, `pg_is_in_recovery=f` |
| CP01-G1 ⛳ | **Cutover gate (PROD: G3 of the parent runbook)**: TARGET_DB verified, the old instance is fenced or agreed not to be, and comms are ready. `DECISION: CUTOVER GO` | IC | 1 | Decision recorded |
| CP01-S05 | **Update the secret**: `./automation/scripts/dr-secret-cutover.sh apply`. It saves the previous VersionId and host (never the password) into evidence, sets `host`, `port`, `dbInstanceIdentifier` (if present), calls `put-secret-value`, then `dr_mark T6` | Executor (+2nd eyes in PROD) | 1 | New VersionId is `AWSCURRENT`; old is `AWSPREVIOUS` |
| CP01-S06 | **Force ESO sync** (do not wait up to `refreshInterval`): run by the script: `kubectl annotate externalsecret $K8S_SECRET force-sync=$(date +%s) --overwrite` | Executor | 1 | ExternalSecret `Ready=True`, `refreshTime` after T6; K8s Secret `DB_HOST` = new endpoint |
| CP01-S07 | **Wait for the Reloader rollouts**: `./automation/scripts/dr-eks-rollout.sh wait` (waits on `rollout status` for every annotated consumer, in `restart-order`). Fallback if Reloader is down or not annotated: `./automation/scripts/dr-eks-rollout.sh restart`. Then `dr_mark T7` | Executor | 5 | All `successfully rolled out`; 0 pods older than T6 among consumers |
| CP01-S08 | **Read-only secret** (UAT/PROD, if `SECRET_ID_RO` is used by read paths that pointed at the replica, which is gone, stale or now primary): `SECRET_ID=$SECRET_ID_RO ./automation/scripts/dr-secret-cutover.sh apply` (temporarily points reads at TARGET_DB). Restore a proper replica in the FB runbook | Executor | 3 | Reader pods rolled; no connections to the old replica |
| CP01-S09 | Restart **unannotated consumers** from S01, delete/re-run in-flight Jobs, and **resume CronJobs** *after* CP-02 passes: `./automation/scripts/dr-eks-rollout.sh resume-cronjobs` | Executor | 3 | Done |

## Rollback (switch the apps back to the previous endpoint)

Only valid while OLD_DB is still intact and writable, i.e. **before** writes have landed on TARGET_DB that you would lose.
```bash
./automation/scripts/dr-secret-cutover.sh rollback     # moves AWSCURRENT back to the saved previous VersionId,
                                                       # force-syncs ESO; Reloader rolls the pods again
```
Equivalent manual command:
`aws secretsmanager update-secret-version-stage --secret-id $SECRET_ID --version-stage AWSCURRENT --move-to-version-id <prev> --remove-from-version-id <new>`

## Pre-requisites (steady state — verify at each runbook review)
- Every DB-consuming workload carries `secret.reloader.stakater.com/reload: "<k8s-secret>"` and `dr.example.com/restart-order`.
- Reloader runs with `reloadStrategy: annotations` when Argo CD/Flux manage the workloads (this avoids GitOps drift), and has ≥ 2 replicas (HA).
- ESO `refreshInterval` ≤ 1 min and the ESO controller is healthy (alert `DRExternalSecretNotReady`).
- Apps fail **readiness** when the DB is unreachable or read-only, and **do not** fail liveness (avoids restart storms).
- The executor role can `secretsmanager:PutSecretValue` / `UpdateSecretVersionStage` on `$SECRET_ID` and patch ExternalSecrets/Deployments in `$K8S_NS`.
