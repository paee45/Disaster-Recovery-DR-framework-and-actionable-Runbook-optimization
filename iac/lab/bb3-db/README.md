# Isolated BB3 Sandbox Database

DB only: one PostgreSQL 17.9 primary and, by default, one physical RDS read replica
in a different AZ. Both default to `db.t4g.micro`, the selected size for this drill.
The custom parameter-group family is `postgres17`, with no user overrides, matching
the observed UAT engine and absence of user-set parameters. Smaller instance sizing
is intentional; it does not establish production performance parity.
This stack creates no EKS, Swarm, application, IAM role, or policy.
It does not manage existing `lab/db` resources or real BB3 databases.

Failback P4-S02 offers an explicit `SIGN-OFF-FAILBACK` approval after the transaction.
Retry reuses the saved transaction and records separate immutable local sign-off with owner,
supporting evidence references and journal/log hashes. Enter leaves sign-off pending; it never
approves deletion. External evidence is not independently verified.
Sign-off reuses the displayed deployment, health and transaction references captured in earlier steps;
it does not ask for three additional supporting references. Missing/invalid prior records still block it.
Existing immutable sign-off records, including previously entered supplemental references, are unchanged.

The standalone retirement script is an owner-approved exception to Terraform-only cleanup:

```bash
bash iac/lab/bb3-db/retire-restored.sh --failback DR-ID
```

It requires completed failback sign-off with no minimum waiting period, and verifies sign-off hashes, current original
endpoints, restored resource IDs, topology and run tags. It shows the exact DB/SG/snapshot/backup
scope before matching-owner approval, a retention decision reference and `RETIRE-RESTORED-PAIR`.
Enter cancels. This one approval includes permanent removal of the restored pair's recovery data;
no second backup approval is required. It creates and verifies a temporary manual safety snapshot,
prints timestamped stages 1-8 and waiter start/completion messages (not a percentage),
deletes the restored replica before the primary, then deletes only their run-owned quarantine
SG after DB/ENI detachment. Finally it deletes automated backups identified by the exact saved
restored DB resource IDs, and deletes the verified retirement-created snapshot. It retains original
DBs and their backups, the source restore snapshot, unrelated snapshots/SGs/networking/secrets and
evidence. Cross-account/Region or mismatched backup identities block deletion. This is a manual
command, not a scheduled job.
Each entered stage shows a bold magenta title and cyan What/Expected labels once,
explaining scope, success criteria, approval requirements and stop/retry behavior.
Stages cover identity/sign-off, live safety, retirement approval, safety snapshot,
replica deletion, primary deletion, quarantine/backup purge, then the final scoped audit.
`NO_COLOR`, dumb terminals and redirected output retain plain explanations. At stage 6,
`modifying` blocks primary deletion: review the in-progress approved change, wait for
completion, then resume the same run; completed replica deletion is not repeated.
No new Terraform stack is used. DB deletion protection is never disabled automatically.
The ignored `retirement.json` pins resources and records progress; rerun the exact command after
an interrupted waiter. Unexpected disappearance or identity/evidence drift stops for investigation.
An incomplete AWS waiter prints the same-run resume command and prevents later stages from running.
Completed retries verify DB/SG/temporary-snapshot/scoped-backup absence without mutations. Local journals and
the original P5 package are not rewritten. The separate existing quarantine helper remains SG-only.
Run `bash iac/lab/bb3-db/test-retire-restored.sh` for visible mocked tests; no live retirement
has been certified by those tests. Do not approve placeholder references as application evidence.
Older journals that retained recovery data require a fresh scope review and the same typed retirement
approval before the new purge policy is applied. Interrupted backup deletion stays incomplete until
absence is verified; rerun the same command, without recreating a snapshot already marked for purge.

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
`bb3-run.sh S3 --only P0-S02 --show` renders the latest table locally without querying AWS.

Before an incident, run the guided discovery once. The `uat` argument selects
`env=uat`; `app=bb3` identifies the application. `local` is not an AWS RDS environment.

```bash
bash iac/lab/bb3-db/bb3-run.sh S3 --list
bash iac/lab/bb3-db/bb3-run.sh S3 --only P0-S01
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
secret values and makes no AWS changes. Capture the original source baseline after
discovery and before the controlled outage:

```bash
bash iac/lab/bb3-db/bb3-run.sh S3 --only P0-S02
```

P0-S03 allocates the DR run ID, creates one run-tagged SG with no ingress, and
replaces the SG attachments on both source DBs. Keep the app health monitor active
and capture the first app connection failure; pausing writers/jobs is not required
for this fault injection. P1-S01-1 records T0 from that evidence; Enter defaults to the displayed
current UTC time. P1-S01-2 records T1 using the same run ID. P3-S01 verifies the
existing quarantine and records session closure; it does not submit another SG
change. The pre-quarantine baseline is pinned: do not recapture it during the run.

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

### Recovery Closeout

After P4-S01 health/T8 and P4-S02 business validation/T9:

```bash
bash iac/lab/bb3-db/bb3-run.sh S3 --only P4-G4
bash iac/lab/bb3-db/bb3-run.sh S3 --only P5
```

P4-G4 records the incident approver and actual declaration time T10, without a ticket-reference prompt,
and one review of the saved T0/T8/T9 evidence references. Enter for restrictions means
`none`; type `DECLARE-RESTORED` to attest the references were reviewed and finalize the
immutable local closeout record. Type `EDIT` instead to correct the three references before
the same final approval. The CLI highlights the stage and RTO result with color when supported,
and explains T0 impact, T1 declaration, T8 health, T9 business validation and T10 approval.
Each milestone has a bold title, its own highlighted UTC time, elapsed-time metric and
plain-English explanation. T0 means T-zero (impact), not TO; T8 is the successful app
health timestamp, while RTO is the duration from T0 to T8.
Service RTO ends at T8; the summary also shows time through T9 and any missed-target margin.
BB3 defaults to a 60-minute RTO because recovery includes both primary and replica. Set
`export BB3_RTO_TARGET_MIN=60` in ignored `iac/sandbox.env`; use `45` or `30` for a stricter
BB3 target. Other framework workflows retain their 30-minute default. The target and
computed metrics are frozen in new approvals, so later config changes do not reclassify
an approved run or its package. Legacy approvals retain their original 30-minute target.
A standalone numeric `export BB3_RTO_TARGET_MIN=...` line is excluded from the runner's
operational config hash, so changing only that reporting policy does not block resume.
All other config drift remains guarded. P4-G4 prints its selected run ID before checking
for an existing immutable approval and explicitly reports when that approval already
exists; it is not a request to repeat recovery sign-off. For failback, supply that actual `DR-...` value;
`{{COMPLETED_CUTOVER_DR_ID}}` is documentation placeholder text, not a usable run ID.

For new guided restores, P2-S01 saves immutable `snapshot-recovery.json` from the selected
AWS snapshot metadata, bound to the run, source DB and restored primary. P4-G4 reports
`RPO: VERIFIED (snapshot-based)` and PASS/MISS using **T0 minus SnapshotCreateTime**, with
a 24-hour target. This verifies the agreed daily-snapshot-age measure; it does not certify
zero data loss or transaction-level completeness. DB/business data-gap verification is
deferred; existing app health and business transaction confirmation gates remain.
Runs without saved snapshot metadata show NOT VERIFIED rather than guessing from current
discovery settings. Existing immutable approvals/packages are not backfilled or rewritten.
Redirected output, `NO_COLOR` and dumb terminals remain plain. Existing records are not rewritten. Runner
steps show What/Expected descriptions by default; `--verbose` remains accepted for compatibility.
Plain `S3` checks saved progress and offers confirmed continuation before running recovery through
T10/P5. Press Enter to accept the suggested action or `n` to cancel; this never approves mutations
or app-owner evidence. It can continue an already-started failback for the displayed saved config
run ID, but never starts a new failback or retirement automatically. `S3 --new` deliberately starts
a separate recovery checkpoint; evidence is retained. Use `S3 --to P2-S09` for RDS-only readiness,
or explicit `--from`/`--only` for controlled manual selection.
Default and ranged sequences call P3-S02 with `--apply` to enter its fence/typed-approval flow;
they never approve the change.
One-command failback uses `S3 --failback DR-ID` for the explicit completed recovery: endpoint preview,
restored-pair fence/session closure, guarded endpoint apply, original-source release, manual deployment
confirmation, health and transaction/sign-off. Add `--list` to inspect without actions. Approval gates,
manual deployment and data reconciliation decisions remain mandatory; this is not a new restore or
automatic retirement. Do not combine top-level failback with step/range selectors. Existing single-step
failback commands remain available for controlled continuation after interruption. Rerunning the
main `S3 --failback DR-ID` command offers the next incomplete action, distinguishing restored fencing
from original release. Atomic ignored checkpoints cover all runner action boundaries; legacy journals
are checked conservatively. Interrupted restore/create probes run ownership/topology before choosing
a waiter or retry, and hardening waits for readiness before revalidation. Config drift, malformed
records, wrong-run targets, changed package/sign-off hashes and untracked evidence edits
remain blocked. A source-quarantine release legitimately
updates `network-fence.json` during failback. The main command accepts that change only when
the matching failback checkpoint records completed release and pins the exact current hash
for the same source pair; all other historical recovery hashes remain checked.
No TTY means no automatic continuation. `--list` never writes progress or calls AWS.

P3-S03 option 1 runs automatic SSH deployment for dev/uat after clean-main preflight and typed
`DEPLOY-ENV` approval; option 2 runs it step-by-step (Enter runs, `n` stops, `s` skips optional checks;
required-step skips prevent attestation); option 3 records an already completed manual deployment and
prints the [BB3 Deployment Guide](https://beep-technologies.atlassian.net/wiki/spaces/BB3/pages/1216610316/BB3+Deployment+Guide#Deploying).
Production SSH deployment is not permitted by this UAT-role workflow. The Docker image/test runs the same
orchestrator through the OpenSSH client/server protocol to an isolated loopback host, with network disabled,
no host mounts and a synthetic Git repo/fake Docker results. It creates a temporary mock container named
`bb3-deploument-ec2` by default and removes it afterward; it is not an EC2 instance or deployment evidence.
Set `BB3_DOCKER_LOCAL_CONTEXT` in the ignored sandbox config/current environment to route P3-S03 to this
Docker SSH mock; Docker errors never fall back to SSH. When blank/unset, P3-S03 uses real SSH. The committed
example leaves it blank; set it to `colima-dr-framework` only to select the local mock. `BB3_DEPLOYMENT_HOST` is validated against `ENV`, and
`BB3_DOCKER_STACK_NAME` defaults to `beepbeep`. Mock PASS alone never records deployment evidence. Failback sign-off writes hash-linked
`failback-report.md`/`.json`; retirement stage 8
writes a versioned `retirement-report-<audit-time>.md` and checksum. Recovery P5 already packages a detailed
`snapshot/summary.md` with RTO/RPO results and limitations.
Append `--real-ssh` to one `--only P3-S03` invocation to override the configured Docker context without
editing `sandbox.env`; typed `DEPLOY-ENV` and host allowlisting still apply.
Both options 1 and 2 continue to normal deployment owner-confirmation prompts after
a successful Docker simulation. Command transcripts are captured automatically;
neither option asks for a full-log paste. With real SSH, the captured command/output
log is reused for owner review/redaction. With the Docker mock, its captured output
stays simulation-only and a single actual-deployment evidence reference is requested
instead of pasted logs. Confirm the actual endpoint/service convergence. Only
that separate owner confirmation records deployment evidence and allows the runner
to continue into health/business validation. Declining or cancelling leaves P3-S03
pending. A failed/cancelled mock stops before these prompts; no real SSH fallback
or automatic attestation is performed.
The three Docker phases use an alternate terminal screen anchored at the top, with
a fixed four-line live-output region. Completion/cancellation restores the main
screen rather than adding the full build/session to its scrollback. Plain/NO_COLOR/
dumb output shows phase messages and at most four recent lines per build/session.
Full build/session logs remain in the displayed local evidence directory.
Automatic command transcripts are Git-ignored, owner-only files, not automatically
sanitized evidence. Review/redact before confirming; no real SSH fallback is attempted.
Only option 3 shows the highlighted manual-deployment explanation and full-log paste
instructions, because deployment happened outside this runner and was not captured here.
Original-quarantine release waits for the exact saved SG attachments to report active, rather than
assuming RDS `available` proves SG convergence. It prints bounded retry progress and retains the SG on
timeout. After live-state review, retry just P3-S01 `--failback DR-ID --release-quarantine`; original DBs
already on their saved SG set are verified without another modification request.
No top-level `--apply` flag is needed: guided failback explicitly calls preview first and guarded apply
after the restored-pair fence. Typed approvals remain mandatory. Incident declaration in recovery records
the selected S3 scenario without asking for S3/S4 again; BB3 S4/PITR is still unsupported.
Failback What/Expected descriptions are action-aware: P3-S02 distinguishes read-only original-return
preview from guarded apply; P3-S01 distinguishes restored-pair fence, original release and SG-only cleanup.
Deployment, health and transaction/sign-off descriptions refer to the original pair and preserve recovery
milestones. The same wording applies to guided and explicit single-step failback commands.
Single-step `--only P3-S02` remains preview-only; add `--apply` to request confirmation, or `--preview`
for read-only inspection.
Full compliance limitations are saved in the report/package rather than
repeated in console output. P5
automatically packages a validated allowlisted local snapshot, SHA-256 manifest/archive and receipt
without additional input. It reuses the closeout approver as evidence owner and the fixed ignored
`evidence/bb3-packages` destination. Deployment logs are omitted, not automatically reviewed or included.
Existing closeout records with ticket references remain compatible; immutable outputs are never overwritten.
It does not upload evidence, make AWS calls, resume jobs or authorize failback. Raw
baselines and external references remain separate. See the runbook closeout section for
all required confirmations and evidence limitations.

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
bash iac/lab/bb3-db/bb3-run.sh S3 --only P0-S01,P0-S02,P0-S03,P1-S01-1,P1-S01-2,P2-S00

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
RDS waiters show elapsed `HH:MM:SS` on one line, updated each second in an interactive terminal,
including primary/replica creation, hardening, fencing and retirement waits. This is elapsed time,
not a percentage or estimated finish time. Redirected output records only the start and final timer lines.
The final `completed in HH:MM:SS` line remains on screen and in captured output;
failed/interrupted waits show the exit result and elapsed duration instead.
Quarantine waits identify primary and replica separately. In redirected logs,
`started` and `completed` lines describe the same wait, not duplicate actions.
Executed step headings are bold magenta; What/Expected labels are cyan. Redirected,
`NO_COLOR` and dumb-terminal output stays plain.
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
python3 iac/lab/bb3-db/test-runner-progress.py
bash iac/lab/bb3-db/test-bb3-deployment-mock.sh
bash iac/lab/bb3-db/test-bb3-deployment-docker.sh
bash iac/lab/bb3-db/test-app-failback-confirm.sh
```

To include scripted guided input and real host-TTY completion/cancellation checks,
run the Docker test with host Expect installed:

```bash
DOCKER_CONTEXT=colima-dr-framework BB3_DOCKER_TEST_GUIDED=1 BB3_DOCKER_TEST_TTY=1 \
	bash iac/lab/bb3-db/test-bb3-deployment-docker.sh
```

Interactive guided completion returns 0; `n` cancels with exit 130. The harness
normalizes the expected stop only for its scripted regression, not for operator
cancellation. Docker simulation never records P3-S03 deployment evidence.

The wrapper test replaces configuration loading, Git ignore checks, AWS, curl and
Terraform with shell stubs. It never reads real sandbox configuration, credentials,
state or secrets, and never invokes cloud tools. Terraform schema validation can
use already-installed providers with backend disabled and credentials removed.
The generated provider lockfile currently has only local `darwin_arm64` checksums;
other platforms need trusted checksums through a separately approved setup.