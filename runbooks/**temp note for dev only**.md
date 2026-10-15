**Choose the restore type**
“Daily backup restore” can mean either of these:

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
./automation/scripts/dr-env-discover.sh dev \
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
source env/dev.env
./automation/scripts/dr-env-check.sh S4   # use S3 for snapshot restore
./automation/scripts/dr-preflight.sh restore
```

Then inspect the runner’s steps and commands without making changes:

```bash
./automation/scripts/dr-run.sh S4 --list
./automation/scripts/dr-run.sh S4 --dry-run
```

For this DEV profile, use `SECRET_MODE=k8s`, confirm the Secret host keys are correct, and verify Reloader plus all database consumers. The preflight reports consumers that need a manual restart.

**Run the recovery**
For a time-specific recovery from automated backups:

```bash
./automation/scripts/dr-run.sh S4
```

For a snapshot restore:

```bash
./automation/scripts/dr-run.sh S3
```

The runner pauses for incident inputs and approval gates. S4 needs the bad-change time, a restore time inside the available PITR window, and a decision between full cutover and side-instance repair. S3 prompts for the snapshot; the newest automated snapshot is the default. Review the restore plan before approving the restore. Both paths then wait for the new instance, harden it against the captured baseline, validate, verify app access, and require cutover approval before changing the endpoint. The cutover updates every configured host key, rolls annotated workloads via Reloader, and checks stale consumers.

If you need to step away, note the printed `DR_ID` and resume that run rather than starting another:

```bash
./automation/scripts/dr-run.sh S4 --resume <DR_ID>
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
./automation/scripts/dr-env-discover.sh dev --profile YOUR_DEV_PROFILE --region ap-southeast-1
# Review env/dev.env before sourcing it
source env/dev.env
./automation/scripts/dr-env-check.sh S3
./automation/scripts/dr-run.sh S3 --list
./automation/scripts/dr-run.sh S3 --dry-run
./automation/scripts/dr-run.sh S3
```


Here are the options for the shared **S3/S4 step runner** in `dr-run.sh`.

**Run it**
```bash
# Local Moto/LocalStack
bash iac/local.sh dr S3 [options]

# Real AWS, after sourcing the reviewed environment file
source env/dev.env
./automation/scripts/dr-run.sh S3 [options]
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
bash iac/local.sh dr S3 --list
bash iac/local.sh dr S3 --dry-run
bash iac/local.sh dr S3 --only P0-S01
bash iac/local.sh dr S3 --to P2-S05
bash iac/local.sh dr S3 --resume DR-20261014-0607-local-S3
```

`DR_RUN_GATES=auto` and `DR_RUN_AUTO_NO=...` are **local test-only** controls, not real-AWS run options.