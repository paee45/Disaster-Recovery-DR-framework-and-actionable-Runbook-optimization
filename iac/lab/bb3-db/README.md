# Isolated BB3 Sandbox Database

DB only: one PostgreSQL 17.9 primary and, by default, one physical RDS read replica
in a different AZ. Both default to `db.t4g.micro`, the selected size for this drill.
The custom parameter-group family is `postgres17`, with no user overrides, matching
the observed UAT engine and absence of user-set parameters. Smaller instance sizing
is intentional; it does not establish production performance parity.
This stack creates no EKS, Swarm, application, IAM role, or policy.
It does not manage existing `lab/db` resources or real BB3 databases.

The [sanitized UAT observation](uat-baseline.sanitized.json) records only prior
read-only API results from 2026-10-19, supplemented with retention from the saved full capture. It is not a full
restore baseline or a `dr-restore`-compatible instance capture. Unknown fields and
full parameter values are omitted, identifiers use placeholders, and `labOverrides`
are lab choices, not source observations. This remains internal configuration
metadata: review internal access policies before sharing.

The full raw capture is saved locally under ignored `baselines/<UTC>-<unique>/`, with
`baselines/latest.json` pointing to the latest complete capture. It includes both full
instance descriptions, tags, 437 API parameters per DB, parameter-group definitions,
security-group rules and subnet metadata, plus an integrity manifest. No credentials
or SQL were collected. Refreshing preserves prior captures; incomplete captures do
not replace the latest reference. Each capture prints a primary/replica summary table;
`bb3-run.sh S3 --only P1-S03 --show` renders the latest table locally without querying AWS.

Before an incident, run the guided discovery once. The `uat` argument selects
`env=uat`; `app=bb3` identifies the application. `local` is not an AWS RDS environment.

```bash
bash iac/lab/bb3-db/bb3-run.sh S3 --list
bash iac/lab/bb3-db/bb3-run.sh S3 --only P1-S02
```

Discovery matches `env=<environment>` plus `app=bb3`; neither tag alone is enough.
It does not depend on the DB identifier prefix. Select a numbered primary, then a
numbered available replica if one is attached. If no primary matches both tags, the
script warns and shows all available PostgreSQL RDS instances in red for careful
manual selection; this fallback has no default and does not imply a verified source.
Saved or sole primary/replica choices are highlighted green, and Enter accepts the
highlighted number. All available automated snapshots are listed newest-first; the
latest is highlighted green and defaults to Enter. If selections differ from those
saved, `[Y/n]` confirms writing `ENV`, `APP`, source IDs, snapshot ID, and deterministic
restore target IDs into the existing ignored `iac/sandbox.env`; Enter accepts Yes, while
`n` cancels. If values already match, no prompt or write occurs. `--print` is available
for a noninteractive preview, while
`--primary`, `--replica`, and `--snapshot` are reviewed overrides. Discovery reads no
secret values and makes no AWS changes. Run capture with no IDs to use the saved
selections:

```bash
bash iac/lab/bb3-db/bb3-run.sh S3 --only P1-S03
```

For an incident-time refresh, rerun guided discovery and review the selected primary,
optional replica, and recovery point before answering `YES`.

Use the **described values** for this drill: primary backup retention **7 days** and
replica backup retention **0 days**. Terraform already matches these values. The earlier
1-day discussion was hypothetical, not the observed UAT setting. Current snapshot
and PITR APIs accept retention and the preferred backup window during restore. The
host AWS CLI was upgraded to 2.38.1 and both fields are submitted from the approved
baseline. The shared runner detects older CLI input models and explicitly defers
only unsupported backup inputs to post-restore `ModifyDBInstance`; hardening and
validation still check the final values. Do not assume the snapshot's data timestamp
implies the current retention configuration was restored.
Other differences such as the smaller sandbox class/storage and new sandbox network
remain explicit lab choices, not claims of exact configuration parity.

Identifiers are `dr-sandbox-bb3-<env>-primary-drill` and
`dr-sandbox-bb3-<env>-replica-drill`. The older unsuffixed identifiers are not
managed by this stack. Environment tags describe a sandbox role, even when
`<env>` is `prod`. Do not replace these identifiers with real BB3 names.

## Prerequisites and State

Use `iac/tf.sh lab/bb3-db <env> ...`, where env is `dev`, `uat`, or `prod`.
The wrapper reads the allowed account and bucket from ignored sandbox config,
accepts `lab_sandbox` (SSO) or `pa_aws_sandbox` (sandbox IAM-user keys) in region
`ap-southeast-1`, checks the
profile account before accessing S3, and pins identity/state inputs on plans.
Do not bypass the wrapper or apply a plan from a different stack, environment,
account, or state key. Saved plan contents still require owner review.

State is separate: `lab/<env>/bb3-db/terraform.tfstate` in the existing sandbox
bucket, with S3 native locking, encryption, and allowed-account checks.
The existing `lab/shared/network/terraform.tfstate` supplies the VPC and AZ placement.
Existing shared network resources are not changed. This stack creates two private
DB/app subnets tagged `dr-sandbox-bb3-<env>-db-app1` and
`dr-sandbox-bb3-<env>-db-app2`, a dedicated local-only route table and two
route-table associations in that VPC. Both are members of the DB subnet group
selected by the snapshot restore request; a same-Region replica inherits its
network placement from the restored primary. RDS subnets cannot be appended after
the DB instance is restored. At plan time, subnet reads verify the first two shared placement subnets
belong to this VPC and occupy different AZs.
Authenticate and inspect the shared network separately before approved planning.

SSO is preferred because its credentials expire. The owner's alternative is an
existing sandbox IAM user through `pa_aws_sandbox`; create the profile with AWS CLI
and enter keys directly in the local terminal, never in chat, repository files,
environment assignments or logs. Do not run credential setup through a recorded
DR session. Use a narrowly scoped sandbox policy, protect/rotate the keys, and
verify `sts get-caller-identity` matches the configured sandbox account before
changing the ignored config to `TF_VAR_aws_profile=pa_aws_sandbox`. The account and
region checks remain mandatory; a profile name alone does not establish identity.

Both DBs have `publicly_accessible=false` with no public-exposure override.
Their dedicated private subnets have no default route to an internet gateway or
NAT gateway. The security group allows TCP 5432 only from the sandbox VPC CIDR;
there is no laptop ingress or operator-IP discovery. No unrestricted ingress or
egress rule is added. Per-environment subnet blocks are derived from the shared
VPC CIDR using distinct offsets; review their availability in the saved plan.

The Mac can run AWS CLI RDS snapshot/restore/configuration commands through AWS
service APIs without a route to the database. SQL access would need a separately
approved VPC access path and custodian credentials; it is not needed for today's
RDS API-only drill. No NAT gateway is required for these managed RDS operations.

## Credentials and Backups

AWS does not support creating a PostgreSQL read replica from a source using
[RDS-managed master credentials](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-secrets-manager.html#rds-secrets-manager-limitations).
Instead, Terraform generates a sensitive 32-character password and writes a
dedicated Secrets Manager secret using the BB3 drill keys `DB_HOST`,
`DB_REPLICA_HOST`, `DB_NAME`, `DB_USER`, and `DB_PASSWORD`. `DB_USER` is the RDS
master user `beepbeep` for this disposable sandbox only; never reuse this pattern
for production application credentials. `DB_REPLICA_HOST` is empty when the
optional replica is disabled. Outputs contain only the secret reference, never
its contents. No DB password input, environment variable, secret read data source,
or automatic rotation is provided. A custodian must separately approve any
credential access or rotation. Keep this credential mode when disabling a replica
so it can later be re-enabled without switching source credential management.

**Terraform state and saved plans contain credential material.** Sensitive marking
redacts ordinary CLI output; it is not encryption of local files. Restrict access
to state, S3 versions, saved plans, backups and JSON plan exports. Never publish
them or run commands that print raw state or secret contents. The secret uses
Secrets Manager's default encryption and a seven-day deletion recovery window.

Source and replica storage are encrypted. Primary backup retention defaults to
seven days and cannot be below seven. The replica inherits the source database,
credentials, encrypted storage and subnet group; it is asynchronous physical
replication, not a Multi-AZ standby. Replica automated backups are disabled.

## Later Approved Usage

### Interactive Snapshot Drill

Use the BB3-only runner to preview and execute each RDS phase independently. It
reads a complete sandbox snapshot and detects whether the source primary has a
read replica. The preview prints only populated API request fields in comparison
tables; `MATCH`, `NEW`, and `DIFF - REVIEW` are text indicators (color is optional).
It never prints or retrieves the Secrets Manager payload.

```bash
# All RDS recovery steps, including automatic availability waits
bash iac/lab/bb3-db/bb3-run.sh S3

# List step IDs, then run only the selected ordered steps
bash iac/lab/bb3-db/bb3-run.sh S3 --list
bash iac/lab/bb3-db/bb3-run.sh S3 --only P1-S02,P1-S03,P2-S00

# Read-only: compare original primary/replica baselines and the API requests
bash iac/lab/bb3-db/bb3-run.sh S3 --only P2-S00

# Read-only: check both saved restore targets
bash iac/lab/bb3-db/bb3-run.sh S3 --only P2-S09

# Separately confirm and start the primary restore; confirmation defaults to No
bash iac/lab/bb3-db/bb3-run.sh S3 --only P2-S01

# Once primary is available: compare/harden parameter group, backup window/retention,
# and maintenance window (maintenance is not accepted by snapshot-restore API)
bash iac/lab/bb3-db/bb3-run.sh S3 --only P2-S03

# Only after primary baseline validation: confirm and create a new replica
bash iac/lab/bb3-db/bb3-run.sh S3 --only P2-S05

# Once replica is available: compare/harden inherited parameter group and maintenance window
bash iac/lab/bb3-db/bb3-run.sh S3 --only P2-S07
```

The all-in-one `S3` sequence waits automatically at the primary and replica availability checkpoints.
Press Ctrl+C during a wait to stop; the runner prints the matching `--only P2-Sxx` resume command. After an
accepted restore/create request, resume at its wait ID rather than resubmitting the mutation.

Restore preview verifies the primary/replica baseline and parameter files against the
checksums in the selected `latest.json` capture and refuses a source/account/region
mismatch. It compares snapshot-returned metadata and `env`/`app` tags to the captured
primary. In `restore`, choose each differing tag: `1` keeps the primary value, `2` uses
the snapshot value. Choices apply only to the new primary/replica tags; `Name` and
`Role=primary` are assigned for the new writer, and `dr-restore` marks its lifecycle.
Non-tag snapshot differences require `ACCEPT-DIFF`. Snapshot APIs do not expose
parameter values. The full captured primary parameter API set is compared to the
current primary group; parameter drift requires `USE-CURRENT-PARAMETERS` or cancel.
After restore, all primary parameters are checked against capture; after replica
creation, all parameters are checked against the original replica (or primary template
if no replica existed). The helper stops if an expected group name has different
values, because it cannot reconstruct historical group contents.

The restore request explicitly supplies the captured subnet group, security groups,
parameter group, class, retention and backup window. `PreferredMaintenanceWindow`
is applied later through `ModifyDBInstance`. For same-Region read replicas, AWS
inherits subnet and parameter groups from the restored primary; the replica create
request intentionally omits these fields. When the source has no replica, preview
shows `Original replica: not present` and uses the primary baseline to plan a new
replica in a different subnet-group AZ. Each mutation has a `[y/N]` confirmation;
Enter defaults to No. The discovery env-file prompt defaults to Yes. Typed GO gates
and owner attestations never default on Enter.
The RDS-only process does not change application secrets or deploy Swarm services.

These are future commands for the parent/operator, not commands run during
implementation. Keep account/bucket values in ignored sandbox config. Set the
explicit operator CIDR there or in the shell; the wrapper does not discover it.

```bash
bash iac/tf.sh lab/bb3-db uat plan -out=bb3-private-uat.plan
```

No operator CIDR is required. Plan files are relative to this stack directory.
Inspect the saved plan locally, obtain owner approval, then apply exactly that plan:

```bash
terraform -chdir=iac/lab/bb3-db show bb3-private-uat.plan
bash iac/tf.sh lab/bb3-db uat apply bb3-private-uat.plan
```

Optional primary override before planning: `export TF_VAR_db_instance_class=db.t4g.small`.
Replica remains `db.t4g.micro`. `TF_VAR_replica_enabled=false` is available for
an explicitly approved topology change, never as a fencing shortcut. Defaults
are private endpoints, replica enabled, and deletion protection disabled for
disposable sandbox teardown. Final snapshots are skipped: decide retention and
preserve evidence before approving destruction.

## Fencing and Teardown

**A primary with a read replica cannot be stopped for fencing.** The existing
`FENCE=stop` recovery path is not suitable for this topology. The wrapper refuses
BB3 `stop` and `start`. Never automatically stop, delete, or promote the replica
to make fencing possible. Choose and validate real fencing separately, including
all writers, before a timed recovery exercise. Recovery RTO is not certified here.

A restored DB does not inherit the source's replica. Rebuilding replication after
recovery needs separate planning and approval. Endpoint changes alone do not
fence the original or reconcile writes. No live sandbox recovery, replication,
fencing, RTO, or Swarm validation is claimed by this implementation.

For later teardown, review restores and other dependencies first. Destroy the
replica before the primary, then the stack-owned secret/network attachments.
Terraform's replica-to-source dependency orders DB deletion correctly. The shared
network must remain until all its consumers and independently restored DBs are
removed. The existing global destroy script does not include this new stack.

```bash
bash iac/tf.sh lab/bb3-db uat plan -destroy -out=bb3-destroy.plan
terraform -chdir=iac/lab/bb3-db show bb3-destroy.plan
bash iac/tf.sh lab/bb3-db uat apply bb3-destroy.plan
```

Obtain owner approval between showing and applying each plan. Teardown is a
separate disposal operation, never part of fencing or an automatic recovery step.

## Offline Checks

```bash
terraform fmt -check iac/lab/bb3-db
bash -n iac/tf.sh
bash -n iac/lab/bb3-db/restore-drill.sh
bash iac/lab/bb3-db/test-wrapper.sh
bash iac/lab/bb3-db/test-restore-drill.sh
```

The wrapper test replaces configuration loading, Git ignore checks, AWS, curl and
Terraform with shell stubs. It never reads real sandbox configuration, credentials,
state or secrets, and never invokes cloud tools. Terraform schema validation can
use already-installed providers with backend disabled and credentials removed.
The generated provider lockfile currently has only local `darwin_arm64` checksums;
other platforms need trusted checksums through a separately approved setup.