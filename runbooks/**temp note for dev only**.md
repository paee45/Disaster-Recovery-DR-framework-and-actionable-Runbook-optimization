## BB3 AWS Sandbox DR Runbook

Use this procedure for the AWS sandbox BB3 PostgreSQL drill. It is **not** real UAT, the local Moto/LocalStack
lab, or the legacy EKS runner. `env/uat.env` belongs to that older EKS lab; BB3 commands read the named profile
and account from the ignored `iac/sandbox.env`. Never fetch or print the mixed secret value.
For commands that invoke repository scripts, use the absolute checkout base `/Users/pa/dr-framework`; they
will work from any current directory. AWS CLI commands are location-independent.

### Scope And Scenario

- **S3** restores a new primary from an approved RDS snapshot. It does not restore an S3 object.
- **S4** is point-in-time recovery. BB3 `restore-drill.sh` currently implements S3 only; BB3 S4 needs a
  separately reviewed PITR implementation. Do not use the EKS `dr-run.sh` for BB3.
- The source may have a primary and replica, or a primary only. A source replica remains attached to the old
  primary after snapshot restore; it is never silently repointed.
- RDS-only completion proves API/configuration/replica topology, not app recovery. App cutover is a separate
  mode with owner approval. T9 requires app-owner confirmation of both endpoints and a successful business
  transaction/readback reference.

### 0. Incident And Identity

Record the incident ID, IC, data owner, app owner, and UTC timestamps. `T0` is when the incident first affected
service; `T1` is incident declaration. Do not substitute the operator's start time for T0.

Verify the named sandbox account before any changes:

```bash
aws --profile pa_iam_aws_sandbox --region ap-southeast-1 sts get-caller-identity
```

Confirm it is the approved sandbox account. Use the approved named SSO profile instead if that is the selected
credential. Never use default credentials or exported keys.

### 1. Capture Original Baseline

Before an incident, run guided discovery and review the sandbox source inputs. The one command can update the
existing ignored `iac/sandbox.env`; it does not create a second env file:

```bash
bash /Users/pa/dr-framework/iac/lab/bb3-db/discover-env.sh uat
```

Select a primary and, if present, an attached replica from the numbered lists. A valid saved selection or a
single eligible match is highlighted green; press Enter to accept it. The snapshot list shows all available
automated backups newest-first, with the latest daily backup highlighted green as the default. Press Enter to
accept it or enter another number. If no primary matches `env=uat` and `app=bb3`, discovery warns and shows
available PostgreSQL RDS instances in red; there is no default in this fallback. The final env-file prompt is
`[Y/n]`, so Enter saves reviewed selections and target IDs; `n` cancels. If all saved values already match,
discovery makes no change. It verifies account/tags/topology and never reads secret values or SQL.

Capture before restore using the saved selections. The helper writes complete read-only AWS API metadata to
the ignored `iac/lab/bb3-db/baselines/` directory, prints a primary/replica summary table, and does not read
Secrets Manager values or SQL:

```bash
bash /Users/pa/dr-framework/iac/lab/bb3-db/capture-baseline.sh
```

To redisplay the latest captured table later without AWS access:

```bash
bash /Users/pa/dr-framework/iac/lab/bb3-db/capture-baseline.sh --show
```

For a one-off source not saved in the env file, pass the primary and optional replica IDs explicitly. A replica
ID may be omitted only when the source primary has no attached replicas.

Primary with replica, explicit one-off:

```bash
AWS_PROFILE=pa_iam_aws_sandbox AWS_REGION=ap-southeast-1 \
  bash /Users/pa/dr-framework/iac/lab/bb3-db/capture-baseline.sh <source-primary-id> <source-replica-id>
```

Primary only, explicit one-off:

```bash
AWS_PROFILE=pa_iam_aws_sandbox AWS_REGION=ap-southeast-1 \
  bash /Users/pa/dr-framework/iac/lab/bb3-db/capture-baseline.sh <source-primary-id>
```

Record the capture directory. Keep that baseline unchanged for the whole run. Confirm parameter groups are
`in-sync`; the capture helper refuses a primary-only capture if AWS reports attached replicas and none were
provided.

### 2. Select Snapshot And Approve Data Loss

Discovery lists all available automated snapshots for the selected source primary and defaults to the newest
daily backup. Review the selected timestamp, status and encryption; `--print` shows the options without
prompting. Record its age and potential lost writes. Obtain data-owner acceptance, including the incident-to-
snapshot loss window, then IC GO. GO is a required typed gate and is never accepted by pressing Enter. Do not
issue restore before this gate.

The selected snapshot and deterministic restore-primary/replica target IDs are saved in `sandbox.env`.

### 3. Preview Restore Requests (No Mutation)

```bash
bash /Users/pa/dr-framework/iac/lab/bb3-db/restore-drill.sh preview
```

The saved snapshot and target IDs are used when arguments are omitted. Positional IDs remain available for
reviewed overrides.

The helper verifies the latest capture's primary/replica baseline files against its checksum manifest and
refuses a source/account/region mismatch. It compares the selected snapshot's available metadata and `env`,
`app`, and `Role` tags against the captured primary, showing only mismatches in red. If mismatches exist, the
restore stage requires the operator to type `ACCEPT-DIFF` before the separate default-No restore confirmation.
RDS snapshot metadata does not expose parameter values; the restore request uses the captured primary
parameter group, and the preview states this limitation. The helper shows primary and replica restore baselines
separately. Tables include populated API-supported request fields: `MATCH`, `NEW`, or `DIFF - REVIEW`. If no source
replica exists, the output explicitly says `Original replica: not present` and uses the primary baseline as the
new replica template.

The snapshot-restore request includes the baseline parameter group, DB subnet group, all VPC security groups,
class/AZ, private access, retention and backup window. Maintenance window is not accepted by that restore API;
it is compared and applied later through `ModifyDBInstance`. For a same-Region read replica, AWS inherits its
subnet and parameter groups from the restored primary, so those fields are intentionally omitted from the
replica-create request. References:
[RestoreDBInstanceFromDBSnapshot](https://docs.aws.amazon.com/AmazonRDS/latest/APIReference/API_RestoreDBInstanceFromDBSnapshot.html),
[CreateDBInstanceReadReplica](https://docs.aws.amazon.com/AmazonRDS/latest/APIReference/API_CreateDBInstanceReadReplica.html),
[ModifyDBInstance](https://docs.aws.amazon.com/AmazonRDS/latest/APIReference/API_ModifyDBInstance.html).

### 4. Restore Primary (Separate Confirmation)

```bash
bash /Users/pa/dr-framework/iac/lab/bb3-db/restore-drill.sh restore
```

The script rechecks the snapshot and unused target, shows any snapshot/baseline differences, then requires
typed `ACCEPT-DIFF` if needed. It displays the primary request table and asks `Submit RESTORE? [y/N]`. Enter
defaults to No; answer `y` only after reviewing target, snapshot, parameter
group, subnet group, SGs, class/AZ, retention/window, and private access. Cancel on an unexplained difference.
This creates a billable DB.

Check both saved target statuses without pasting identifiers:

```bash
bash /Users/pa/dr-framework/iac/lab/bb3-db/restore-drill.sh status
```

Continue only when status is `available`. If a request was accepted but a command/session failed, inspect the
target and state; never submit the restore again under a new target without reconciliation.

### 5. Harden And Validate Primary

```bash
bash /Users/pa/dr-framework/iac/lab/bb3-db/restore-drill.sh harden-primary
```

This compares original baseline, current restored settings, and populated `ModifyDBInstance` fields. If
needed, it asks `Submit APPLY-PARAMETER-GROUP? [y/N]` before changing parameter group, backup retention/window,
and maintenance window. Enter defaults to No. Recheck `available`, parameter group `in-sync`, subnet group,
SG set, private exposure, class, retention and windows before creating the replica.

### 6. Create And Harden Replica (Separate Confirmations)

```bash
bash /Users/pa/dr-framework/iac/lab/bb3-db/restore-drill.sh replica
```

This step requires the restored primary to be available, baseline-matched, private, and parameter-group
`in-sync`. The table shows only accepted `CreateDBInstanceReadReplica` values. AWS inherits the same-Region
replica's subnet and parameter groups from the restored primary. Enter `y` only after review at the
`Submit CREATE-REPLICA? [y/N]` prompt; Enter cancels.

After the replica is available:

```bash
bash /Users/pa/dr-framework/iac/lab/bb3-db/restore-drill.sh harden-replica
```

This verifies the new replica is attached to the restored primary and has matching SG/subnet topology, then
compares/hardens supported parameter-group and maintenance-window settings. Replica retention `0` is expected;
do not apply the primary's 7-day retention to it. Record primary-ready and full-topology-ready timestamps
separately.

### 7. Optional App Cutover: Choose One Mode

Only after RDS validation, inventory all writers/readers/jobs, review fencing, and obtain P3-G0 GO. GO must be
typed explicitly and is never defaulted. Select and
record `APP_CUTOVER_MODE=manual` or `ssh-script`. Both modes update only these fields in the existing mixed
secret:

- `DB_HOST` = restored primary endpoint.
- `DB_REPLICA_HOST` = new replica endpoint.
- Preserve `DB_NAME`, `DB_USER`, `DB_PASSWORD` and unrelated keys.

**Manual:** the authorized custodian updates the two endpoints and records old/new secret version IDs. The
app owner connects to the approved host and runs the approved `scripts/deploy.sh <dev|uat|prod>` or reviewed
restart procedure at the pinned commit SHA. Verify all expected services/tasks converge.

**SSH script:** use only after reviewing the actual `bb3-infrastructure` GitHub deployment script at the
approved SHA and verifying it updates both endpoint keys server-side without logging secret values. The
app owner approves the host; script verifies clean `main`, fast-forward pulls, pins the SHA, updates endpoints
only if that feature is verified, deploys and checks Swarm convergence. Dev/uat only until production is
separately approved. The external repo is not in this workspace, so this mode is not yet certified.

Do not stop, delete or promote source DBs ad hoc. An endpoint update alone does not prove existing tasks have
loaded the new secret version; keep scheduled writers paused until app validation succeeds.

### 8. App Validation And T9

The app owner must confirm `yes/no` for both displayed endpoints, complete the approved business transaction
on the restored primary and the intended readback through the new replica path, and record the transaction
number/reference, UTC time, service/task version, owner and sanitized evidence. Do not include credentials or
business payloads. If either endpoint or the transaction fails, stop: no T9 and no restored-service claim.
Only app-owner GO after successful proof records T9. `available`, matching configuration, or green deployment
is not business recovery.

### 9. Failback And Postmortem

Failback is a separate approved change. Account for writes on the restored DB and obtain data-owner
reconciliation/sign-off first. Then use the selected manual/SSH mode to return both endpoint keys to the
approved failback primary/replica, redeploy/restart, and repeat endpoint confirmation plus business
transaction/readback before failback T9. Keep restored DBs and snapshots until reconciliation and retention
decisions are approved; never auto-delete them.

Record T0/T1/T2/T4/T5/T6/T7/T9/T10, snapshot reference and age, baseline and diff tables, approvals, old/new
secret version IDs only, deployed SHA, task convergence, transaction reference, and final evidence hashes.
Calculate business RTO as T9-T0; report replica/topology recovery separately. Postmortem: incident cause,
data loss/reconciliation, timing by step, parameter/network mismatches, app transaction result, manual work,
delays/failures, RTO/RPO misses, action owner/due date, and required changes before the next drill.

BB3 S4/PITR is not implemented in this helper. Do not use the EKS runner for BB3 PITR; add and review a
BB3-specific PITR request/approval flow before running that scenario.

## Legacy DEV/EKS Reference

The following material applies to DEV EKS and the local Moto/LocalStack lab, not the BB3 AWS sandbox Swarm run.

**Choose the restore type**





**Choose the restore type**
“Daily backup restore” can mean either of these:

OPTION: First, check whether the local test containers are up:
>>bash /Users/pa/dr-framework/iac/local.sh doctor

The required drtest-pg-restored container isn’t in the running list. First check whether it’s stopped or missing:
drtest-pg-restored Exited (0) 6 hours ago
>>bash /Users/pa/dr-framework/iac/local.sh db restored start
Review the displayed plan and type APPLY when prompted. Send me the result before the next step. >>> Verified drtest-pg-restored running=true; data volume preserved.

>>>bash /Users/pa/dr-framework/iac/local.sh ready
Engine: colima-dr-framework | linux/aarch64 | 28.4.0
Context: colima-dr-framework
deployment "app-d" successfully rolled out
deployment "app-e" successfully rolled out
deployment "reloader-alert-sink" successfully rolled out

>>>bash /Users/pa/dr-framework/iac/local.sh dr S3 --dry-run



- **S3** in this repo means *restore from a snapshot* (not a backup stored in an S3 bucket). Use it when restoring to a daily snapshot point.
- **S4** means *point-in-time restore from RDS automated backups*. Use it when you know when the bad change happened and need a restore point just before it. The configured retention is seven days.

For a bad migration or accidental data change, prefer **S4** when the restore window is available. Otherwise, use the latest suitable automated snapshot with **S3**.

**Prepare DEV**
Start with `README.md`, the runbook catalogue, and account and cluster safety. The detailed procedures are DEV S3, DEV S4, and DEV post-restore cleanup.

1. Install the workstation tools listed in docs/12, use a **named** AWS profile, and log in. Don’t use default credentials or exported AWS keys.

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
aws sso login --profile dr-dev
aws --profile dr-dev --region eu-west-1 sts get-caller-identity
```

2. Create the per-environment kubeconfig if needed, then unset its current context:

```bash
aws --profile dr-dev --region eu-west-1 eks update-kubeconfig \
  --name <DEV-EKS-cluster> --alias dr-dev \
  --kubeconfig "$HOME/.kube/dr-dev.config"
KUBECONFIG="$HOME/.kube/dr-dev.config" kubectl config unset current-context
```

The cluster also needs the `kube-system/dr-cluster-identity` ConfigMap identifying `env=dev` and the correct account; see docs/12. The guard refuses to run if identity or context checks fail.

**Generate the env file**
`dr-env-discover.sh` queries AWS and, when it can access the cluster, reads Kubernetes Secret **names and key names only**. It does not read password values. It writes `env/dev.env` with mode `0600`; that real env file is git-ignored. Preview first:

```bash
bash /Users/pa/dr-framework/automation/scripts/dr-env-discover.sh dev \
  --profile dr-dev --region eu-west-1 \
  --db <current-primary-id> \
  --cluster <DEV-EKS-cluster> --context dr-dev \
  --namespace app --secret <app-db-secret> \
  --kubeconfig "$HOME/.kube/dr-dev.config" --print
```

If the preview is correct, run the same command without `--print` to write the file. If `env/dev.env` already exists, discovery refuses to overwrite it; use `--force` only after reviewing it, since the script saves a `.bak`.

Discovery can usually fill the account/profile, primary ID and RDS properties, tags, evidence bucket, matching quarantine security group, EKS name/context, and Secret/key names. It leaves a TODO or note when it can’t find a unique value.

Review and fill missing values such as the app health URLs, tables to verify, incident ticket, and any cluster/Secret selection it could not resolve. Keep `DB_SUBNET_GROUP`, `DB_SG`, `DB_PARAM_GROUP`, and `DB_INSTANCE_CLASS` empty unless an approved override is needed: restore settings are captured from the live source baseline. Don’t put passwords in the env file.

With the current `SECRET_MODE=k8s`, app credentials must be available through the configured Kubernetes Secret for automated login checks. `MASTER_SECRET_ID` is an **identifier** needed by helpers that use master credentials, such as fencing or `fix-password`; if the master password exists only in an external note, the scripts cannot retrieve it. Have the DBA perform those steps through the approved secure process, or provision a secure secret source. Never paste the password into the env file.

**Check before running**
Source the generated file and make both checks pass:

```bash
source /Users/pa/dr-framework/env/dev.env
bash /Users/pa/dr-framework/automation/scripts/dr-env-check.sh S4   # use S3 for snapshot restore
bash /Users/pa/dr-framework/automation/scripts/dr-preflight.sh restore
```

Then inspect the runner’s steps and commands without making changes:

```bash
bash /Users/pa/dr-framework/automation/scripts/dr-run.sh S4 --list
bash /Users/pa/dr-framework/automation/scripts/dr-run.sh S4 --dry-run
```

For this DEV profile, use `SECRET_MODE=k8s`, confirm the Secret host keys are correct, and verify Reloader plus all database consumers. The preflight reports consumers that need a manual restart.

**Run the recovery**
For a time-specific recovery from automated backups:

```bash
bash /Users/pa/dr-framework/automation/scripts/dr-run.sh S4
```

For a snapshot restore:

```bash
bash /Users/pa/dr-framework/automation/scripts/dr-run.sh S3
```

The runner pauses for incident inputs and approval gates. S4 needs the bad-change time, a restore time inside the available PITR window, and a decision between full cutover and side-instance repair. S3 prompts for the snapshot; the newest automated snapshot is the default. Review the restore plan before approving the restore. Both paths then wait for the new instance, harden it against the captured baseline, validate, verify app access, and require cutover approval before changing the endpoint. The cutover updates every configured host key, rolls annotated workloads via Reloader, and checks stale consumers.

If you need to step away, note the printed `DR_ID` and resume that run rather than starting another:

```bash
bash /Users/pa/dr-framework/automation/scripts/dr-run.sh S4 --resume <DR_ID>
```

After cutover, finish app-session and end-to-end checks, collect evidence, and follow the separate post-restore cleanup runbook. For S4, reconcile writes after the restore point with DBA/app-owner review before any failback or old-instance cleanup. The current local S4 also has a Terraform normalization stage; real DEV env changes follow the cleanup runbook and its reviewed IaC process.


The steps below are for **S3 snapshot restore**. The `P*` IDs are from the automated runner, `dr-run.sh`. The manual runbook uses a different numbering scheme for some steps.

| Runner step | What happens in a real S3 DR |
|---|---|
| `P0-S01` | Check env, tools, AWS account/role, and EKS context. |
| `P0-S02` | Preflight: confirm the DB, snapshots, Secret, and app prerequisites. |
| `P0-S03` | Set `OLD_DB` and the new `RESTORED_DB` identifier. |
| `P1-S01` | Record incident start and impact time. |
| `P1-S02` | List snapshots and select one. The runner prefers the newest automated snapshot by default; you can choose another. |
| `P1-G1` | Human approval to restore, acknowledging data written after the snapshot may be lost. |
| `P2-S00` | Preview the restore request; no restore yet. |
| `P2-S01` | Restore the selected snapshot to a new RDS instance. This creates a billable resource. |
| `P2-S02` | Inventory DB consumers and suspend CronJobs while recovery proceeds. |
| `P2-S03` | Wait for the restored instance to become available. |
| `P2-S04` | Apply baseline settings and validate the restored instance. |
| `P2-S05` | Verify app credentials, DB settings, SQL checks, and row counts. |
| `P3-G0` | Human approval to cut over after validation. |
| `P3-S01` | Fence the old DB to prevent unintended writes. |
| `P3-S02` | Update the app’s endpoint Secret and roll the consumers. |
| `P3-S03` | Resume CronJobs and check/restart any stale consumers. |
| `P4-S01` | Verify app sessions use the restored DB, not the old one. |
| `P4-S02` | Run a real application smoke transaction and record its reference. |
| `P4-G4` | Declare service restored. |
| `P5-S01` | Collect and upload the evidence bundle. |

For **real AWS**, use the same runner and IDs, but source the reviewed real environment file. Don’t use the local wrapper:

```bash
aws sso login --profile YOUR_DEV_PROFILE
bash /Users/pa/dr-framework/automation/scripts/dr-env-discover.sh dev --profile YOUR_DEV_PROFILE --region ap-southeast-1
# Review env/dev.env before sourcing it
source /Users/pa/dr-framework/env/dev.env
bash /Users/pa/dr-framework/automation/scripts/dr-env-check.sh S3
bash /Users/pa/dr-framework/automation/scripts/dr-run.sh S3 --list
bash /Users/pa/dr-framework/automation/scripts/dr-run.sh S3 --dry-run
bash /Users/pa/dr-framework/automation/scripts/dr-run.sh S3
```


Here are the options for the shared **S3/S4 step runner** in `dr-run.sh`.

**Run it**
```bash
# Local Moto/LocalStack
bash /Users/pa/dr-framework/iac/local.sh dr S3 [options]

# Real AWS, after sourcing the reviewed environment file
source /Users/pa/dr-framework/env/dev.env
bash /Users/pa/dr-framework/automation/scripts/dr-run.sh S3 [options]
```

Use `S4` instead of `S3` for PITR. The local wrapper currently accepts only `S3` and `S4`.

**Runner options**
- `--help` — show usage.
- `--list` — list step IDs and actions; no DR steps run.
- `--dry-run` — preview the selected steps; no DR changes run.
- `--only P1-S02,P2-S00` — run only the listed step IDs.
- `--skip P1-S01,P4-S02` — omit those steps.
- `--from P2-S00` — start at this step and continue.
- `--to P2-S05` — stop after this step.
- `--from P2-S00 --to P2-S05` — run that inclusive range.
- `--resume DR-ID` — continue an interrupted run using its saved inputs and evidence.
- `--on-fail ask|stop|continue` — choose how to handle a failed step. Default is `ask` in a terminal and `stop` without one.
- `-q` or `--quiet` — suppress live step output; logs are still recorded.

There isn’t a `--start` or `--stop` option: use `--from` and `--to`. A gate is separate from step failure handling: type `GO` to pass it or `NO` to stop at that gate.

**Inputs**
For S3, the runner may ask for `SNAPSHOT_ID`, `RESTORED_DB`, `OLD_DB`, `T0_AT`, and the end-to-end test reference. For S4, it may ask for `BAD_TS` or `RESTORE_TS`, `RESTORE_MODE` (`A` or `B`), and the same DB/test-reference inputs. You can export inputs beforehand to skip their prompts; accepted inputs are saved for resume.

Examples:
```bash
bash /Users/pa/dr-framework/iac/local.sh dr S3 --list
bash /Users/pa/dr-framework/iac/local.sh dr S3 --dry-run
bash /Users/pa/dr-framework/iac/local.sh dr S3 --only P0-S01
bash /Users/pa/dr-framework/iac/local.sh dr S3 --to P2-S05
bash /Users/pa/dr-framework/iac/local.sh dr S3 --resume DR-20261014-0607-local-S3
```

`DR_RUN_GATES=auto` and `DR_RUN_AUTO_NO=...` are **local test-only** controls, not real-AWS run options.



I’ll walk through the local S3 run from lab setup to evidence, including which scripts own each step and what actually mutates state. I’ll ground it in the current runner and call out local-Moto limits plus where S4 differs, rather than treating the simulator as real RDS.

Ran terminal command:  rg -n '^(case|create_local_lab|dr_runner|  (create|prepare|mock|addons|workloads|ready|test|dr)\))|local_env|cat >.*local\.env|^s_S3_|^s_S4_|^NEEDS|^P[0-9A-Z-]+\|' iac/local.sh iac/local/dr.sh tests/local/up.sh automation/scripts/dr-run.sh

Read , lines 150 to 245

The local setup doc confirms this path is an isolated Colima/k3s lab with Moto/LocalStack APIs and fixture Postgres, not AWS. The runner has separate setup and DR orchestration layers; I’m reading their exact responsibilities and gate/dependency behavior next so the walkthrough can explain what each command does and what it deliberately won’t do.

Read , lines 20 to 155

Read , lines 200 to 237

Read , lines 55 to 125

Read , lines 340 to 435

The execution map is clear: `local.sh` injects only selected inputs into `dr.sh`, and `dr-run.sh` owns ordered steps, prerequisites, resumability, and gates. I’m checking the run loop and evidence mechanics now, then I’ll give you a practical command-by-command guide with the exact stopping points.

Ran terminal command:  rg -n 'dr_init|--resume|while .*IDS|NEEDS|save_vars|record\(|run_step|STOPPED|gate\(' automation/scripts/dr-run.sh automation/scripts/dr-lib.sh

Read , lines 1 to 55

Read , lines 445 to 547

Read , lines 116 to 180

I’ve traced the orchestration and recovery helpers. One important current-state caveat: the local app already points at the completed S3 restore, and a separate Moto PITR target exists, so the lab is not at a clean pre-DR starting point; I’ll make that explicit in the walkthrough and mark where a fresh run should pause before cutover.

**Local S3 DR walkthrough**
Local S3 means **restore from an RDS-style snapshot**, not from an S3 backup bucket.

The local lab is already running. The normal entry point is `bash `local.sh` dr S3`; `local.sh` selects the Colima Docker context and passes the permitted run inputs to `dr.sh`. Inside the container, `dr.sh` loads the generated `local.env`, checks that the profile/account/context identify the local fixture, then starts `dr-run.sh`. You don’t need to source the local env file yourself.

Before a run, inspect without changing anything:

```bash
bash /Users/pa/dr-framework/iac/local.sh doctor
bash /Users/pa/dr-framework/iac/local.sh ready
bash /Users/pa/dr-framework/iac/local.sh dr S3 --list
bash /Users/pa/dr-framework/iac/local.sh dr S3 --dry-run
```

The local lab is Terraform-managed. Don’t use `up.sh` or `down.sh` to reset it; they are legacy scripts. A clean baseline requires a reviewed reset/rebuild plan, and evidence should be preserved.

**What the S3 steps do**
1. **P0 preflight:** Check required variables, tools, local AWS identity and Kubernetes context; then check the source DB, snapshots, Secret, and Reloader. `OLD_DB` is the current source; `RESTORED_DB` is a new target.
2. **P1 incident and snapshot:** Record incident timing, list snapshots, and select one. The default is the newest automated snapshot. `P1-G1` asks for explicit approval to restore, acknowledging that writes after that snapshot may be lost.
3. **P2 plan:** `dr-restore.sh plan snapshot` captures or loads the source baseline (RDS settings, tags, and PostgreSQL settings), builds the request, and makes no restore call.
4. **P2 restore:** `dr-restore.sh snapshot` submits the restore API request for a new target. The runner inventories consumers and suspends CronJobs, then waits for the target to become available.
5. **P2 harden and verify:** `dr-restore.sh harden` converges the target to the captured baseline and validates its settings. Then the runner checks app credentials, PostgreSQL settings, SQL health, and row counts. If password repair is needed, the new guard in `dr-secret-cutover.sh` first verifies the Secret host matches the original DB endpoint before it will reset a password.
6. **P3 cutover:** `P3-G0` requires approval. The runner fences the old DB, updates the Secret to the restored endpoint, waits for Reloader rollouts, resumes CronJobs, and checks for stale consumers.
7. **P4/P5 closeout:** Verify app sessions use the new DB, perform a real app transaction, approve service restoration, and collect evidence.

The runner logs each step under `tests/local/.state/evidence/<DR_ID>/`. Inputs are saved for `--resume`; failed prerequisites block dependent steps, so a failed validation cannot flow into cutover. See `dr-run.sh` for the step list and control flow, and CP-01 for the endpoint/password procedure.

**Important for this lab right now**
This is a walkthrough, not a clean start: the app currently points at the previous S3 restore, `app-pg-local-r202610140826`, and a separate Moto PITR test target exists. The prior S3 target’s settings and PostgreSQL parameters passed validation. Don’t launch a fresh full S3 run against the current state without first reviewing how to establish a clean fixture; its source and Secret no longer represent the original pre-DR arrangement.

LocalStack/Moto and fixture Postgres let us exercise the scripts and control flow, but they do not recreate historical snapshot data or prove AWS restore behavior. S4’s local PITR window is synthetic as well.