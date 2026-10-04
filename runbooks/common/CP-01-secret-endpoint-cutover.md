# CP-01 — Secret Endpoint Cutover (K8s Secret or Secrets Manager → Reloader)

**Used by:** S2, S3, S4 (all envs), and FB runbooks that change the instance identifier. **Not used by S1** (the Multi-AZ endpoint does not change).
**Automation:** `automation/scripts/dr-secret-cutover.sh` (both modes) · SSM `DR-UpdateDbSecretEndpoint` (**`eso` mode only** — it writes Secrets Manager).
**Budget:** 10 min (PROD), up to the slowest Deployment's rollout time.

## Two modes — pick per environment (`SECRET_MODE` in `env/<env>.env`)

| | `SECRET_MODE=k8s` — **simple, current default** | `SECRET_MODE=eso` — **target (to-do)** |
|---|---|---|
| Source of truth | The Kubernetes Secret itself | Secrets Manager secret (`SECRET_ID`) |
| How the endpoint changes | `k8s-secret-endpoint.sh` patches **every** host key in `K8S_HOST_KEY` (e.g. `POSTGRES_DB_HOST1,POSTGRES_DB_HOST2`) to the same endpoint in **one** patch | `put-secret-value`, then ESO syncs the K8s Secret (its template must map `host` to every host key) |
| Record of previous endpoint | **Ledger ConfigMap** `dr-endpoint-ledger-<secret>`: one entry per change with its **ID**, old→new value per key, old/new **DB identifier**, who/when; plus annotations on the Secret | Secrets Manager versions (`AWSPREVIOUS` = one step back only) + evidence |
| Undo / failback | `rollback` (undo the latest change) or **`failback <id>`** (endpoint in place before any earlier change) | `rollback` (one step) or `apply` with `TARGET_DB=<original>` |
| Extra components | none (kubectl only) | ESO + IAM for ESO |
| Caveat | Not for a Secret owned by an ExternalSecret (ESO would revert it) — the tool **refuses** that | Rotation must be suspended during the cutover |

**Change IDs (reference for failback):** every change carries an ID = the DR id of the event, format
`DR-<yyyymmdd>-<hhmm>-<env>-<scenario>` (UTC), e.g. `DR-20261004-0930-uat-S3`; a failback gets its own id
(`DR-20261005-1000-uat-FB-S3S4`) and references the change it reverses (`ref`). Several DRs/failbacks in a row are
fine: `dr-secret-cutover.sh history` lists them all, and `failback <id>` jumps back to the state before any of them.
Optional `DR_TICKET=INC-1234` is stored in each entry.

```bash
./automation/scripts/dr-secret-cutover.sh show       # current endpoint per key + last change id / DB id
./automation/scripts/dr-secret-cutover.sh history    # #1 CUTOVER DR-…-S3  app-pg-uat → app-pg-uat-r2026…  POSTGRES_DB_HOST1=… by …
#2 …
./automation/scripts/dr-secret-cutover.sh failback DR-20261004-0930-uat-S3      # back to the endpoint before that change
```
The same is available without the DR scripts (manual use, any secret):
`automation/scripts/k8s-secret-endpoint.sh --context $EKS_CONTEXT -n $K8S_NS -s $K8S_SECRET -k $K8S_HOST_KEY {show|history|set|rollback|failback}`.

## How the chain works (SECRET_MODE=eso; in k8s mode the first two boxes are replaced by one direct patch)

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
| Apps that read the secret **directly from Secrets Manager** (SDK, not the K8s Secret) | Not restarted, and may cache | Restart manually (`kubectl --context $EKS_CONTEXT rollout restart`) or check the app's cache TTL |
| Connection poolers (PgBouncer) | They hold the upstream host | Annotate them too, with `restart-order 1` |

## Steps

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| CP01-S01 | **Inventory consumers**: `./automation/scripts/dr-eks-rollout.sh inventory` lists every workload that mounts/env-refs `$K8S_SECRET`, with or without a Reloader annotation | Executor | 1 | No unannotated consumers, or the list is noted for manual restart |
| CP01-S02 | **`eso` mode only — suspend secret rotation** (a rotation run would race with the cutover; `k8s` mode has no Secrets Manager rotation: skip): `aws --profile $AWS_PROFILE --region $AWS_REGION secretsmanager cancel-rotate-secret --secret-id $SECRET_ID` (only if `RotationEnabled=true`; record this so rotation is re-enabled in CP-03) | Executor | 1 | `RotationEnabled=false` (k8s mode: n/a) |
| CP01-S03 | **Suspend CronJobs** that use the DB: `./automation/scripts/dr-eks-rollout.sh suspend-cronjobs` | Executor | 1 | Listed CronJobs `suspend=true` |
| CP01-S04 | **Pre-verify credentials on TARGET_DB *before* switching**: `./automation/scripts/dr-secret-cutover.sh precheck`. ⚠ **S3/S4 trap:** a restored DB holds passwords **as of the restore point**. If the app password was rotated since then, the password in the secret (k8s mode: `$K8S_PASSWORD_KEY` in the K8s Secret; eso mode: Secrets Manager) fails. The script reports this, and `fix-password` resets the role password on TARGET_DB to that value (needs the master credentials) | DBA | 3 | `login OK as $APP_DB_USER on TARGET_DB`, `pg_is_in_recovery=f` |
| CP01-G1 ⛳ | **Cutover gate (PROD: G3 of the parent runbook)**: TARGET_DB verified, the old instance is fenced or agreed not to be, and comms are ready. `DECISION: CUTOVER GO` | IC | 1 | Decision recorded |
| CP01-S05 | **Update the endpoint**: `./automation/scripts/dr-secret-cutover.sh apply`. **`SECRET_MODE=k8s`:** patches **every key in `$K8S_HOST_KEY`** (e.g. `POSTGRES_DB_HOST1,POSTGRES_DB_HOST2`; and `$K8S_PORT_KEY`) in the K8s Secret in **one** patch, so Reloader restarts the pods once; records old → new per key, old/new DB identifier, who/when under the change id (`CUTOVER_ID`, default `$DR_ID`) in the ledger ConfigMap `dr-endpoint-ledger-<secret>`, and labels the Secret (`dr.example.com/cutover-id`, `endpoint-db-id`); refuses a Secret owned by an ExternalSecret. **`SECRET_MODE=eso`:** saves the previous VersionId and host (never the password) into evidence, sets `host`, `port`, `dbInstanceIdentifier`, calls `put-secret-value`. Either way: then `dr_mark T6` | Executor (+2nd eyes in PROD) | 1 | k8s: `APPLIED`, every host key = new endpoint, `history` shows the change · eso: new VersionId is `AWSCURRENT`, old is `AWSPREVIOUS` |
| CP01-S06 | **`eso` mode only — force ESO sync** (do not wait up to `refreshInterval`; `k8s` mode has no ESO: the Secret is already updated, skip). Run by the script: `kubectl --context $EKS_CONTEXT annotate externalsecret $K8S_SECRET force-sync=$(date +%s) --overwrite` | Executor | 1 | ExternalSecret `Ready=True`, `refreshTime` after T6; K8s Secret host key(s) = new endpoint (k8s mode: n/a) |
| CP01-S07 | **Wait for the Reloader rollouts**: `./automation/scripts/dr-eks-rollout.sh wait` (waits on `rollout status` for every annotated consumer, in `restart-order`). Fallback if Reloader is down or not annotated: `./automation/scripts/dr-eks-rollout.sh restart`. Then `dr_mark T7` | Executor | 5 | All `successfully rolled out`; 0 pods older than T6 among consumers |
| CP01-S08 | **Read-only secret** (UAT/PROD, if `SECRET_ID_RO` is used by read paths that pointed at the replica, which is gone, stale or now primary): **k8s mode:** `CUTOVER_SECRET=ro TARGET_DB=<new endpoint instance> ./automation/scripts/dr-secret-cutover.sh apply` (uses `K8S_SECRET_RO` and `K8S_HOST_KEY_RO`, own ledger, no T6/T7); **eso mode:** `SECRET_ID=$SECRET_ID_RO ./automation/scripts/dr-secret-cutover.sh apply`. Temporarily points reads at TARGET_DB. Restore a proper replica in the FB runbook | Executor | 3 | Reader pods rolled; no connections to the old replica |
| CP01-S08b | **Stale check**: `./automation/scripts/dr-eks-rollout.sh check` (or by hand: `k8s-secret-consumers.sh --context $EKS_CONTEXT -n $K8S_NS -s $K8S_SECRET check`) lists every consumer still running pods older than the Secret change | Executor | 1 | `stale=0`, or only the unannotated ones you chose to leave |
| CP01-S09 | Restart **unannotated consumers** from S01 (`./automation/scripts/dr-eks-rollout.sh restart-stale` restarts only the STALE ones), delete/re-run in-flight Jobs, and **resume CronJobs** *after* CP-02 passes: `./automation/scripts/dr-eks-rollout.sh resume-cronjobs` | Executor | 3 | Done |

## Rollback (switch the apps back to the previous endpoint)

Only valid while OLD_DB is still intact and writable, i.e. **before** writes have landed on TARGET_DB that you would lose.
```bash
./automation/scripts/dr-secret-cutover.sh rollback     # k8s: undo the latest ledger change (refused if the Secret was
                                                       #      changed outside the ledger since — check `show`)
                                                       # eso: AWSCURRENT back to the saved VersionId + ESO force-sync
./automation/scripts/dr-secret-cutover.sh failback <change-id>   # k8s: endpoint in place BEFORE that change (any depth)
```

## Notification — did Reloader restart the pods?
Reloader has **no UI**. Three ways to see what it did:
1. **Chat alert per reload** (recommended): `ALERT_ON_RELOAD=true` + `ALERT_SINK=slack|teams|gchat` + webhook URL in a
   Secret (see `automation/k8s/reloader-values.yaml`). Message: *"Reloader detected changes in secret app-db-direct… Hence
   reloaded app-d in namespace app"* + cluster info. Post it to the incident channel during DR.
2. **Metrics**: `reloader_reload_executed_total{success, namespace}` → alerts `DRReloaderReloadFailed` (page) and
   `DRReloaderReloadExecuted` (info) in `automation/k8s/prometheus-rules.yaml`.
3. **Our own report** (evidence): `dr-eks-rollout.sh wait` writes `reload-report-<secret>.txt` (RELOADED / RELOADER
   FAILED → manual restart / UNANNOTATED → SKIPPED), and `k8s-secret-consumers.sh check` lists pods still on the old secret.

Equivalent manual command:
`aws --profile $AWS_PROFILE --region $AWS_REGION secretsmanager update-secret-version-stage --secret-id $SECRET_ID --version-stage AWSCURRENT --move-to-version-id <prev> --remove-from-version-id <new>`

## Pre-requisites (steady state — verify at each runbook review)
- Every DB-consuming workload carries `secret.reloader.stakater.com/reload: "<k8s-secret>"` and `dr.example.com/restart-order`.
- Reloader runs with `reloadStrategy: annotations` when Argo CD/Flux manage the workloads (this avoids GitOps drift), and has ≥ 2 replicas (HA).
- ESO `refreshInterval` ≤ 1 min and the ESO controller is healthy (alert `DRExternalSecretNotReady`).
- Apps fail **readiness** when the DB is unreachable or read-only, and **do not** fail liveness (avoids restart storms).
- The executor role can `secretsmanager:PutSecretValue` / `UpdateSecretVersionStage` on `$SECRET_ID` and patch ExternalSecrets/Deployments in `$K8S_NS`.
