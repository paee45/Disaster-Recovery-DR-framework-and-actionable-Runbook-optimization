## BB3 AWS Sandbox DR Runbook

Use this procedure for the AWS sandbox BB3 PostgreSQL drill. It is **not** real UAT, the local Moto/LocalStack
lab, or the legacy EKS runner. `env/uat.env` belongs to that older EKS lab; BB3 commands read the named profile
and account from the ignored `iac/sandbox.env`. Never fetch or print the mixed secret value.
Run repository commands from the repository root. Commands below use project-relative paths, so they work
without knowing the local checkout location. AWS CLI commands are location-independent.

### Scope And Scenario

- **S3** restores a new primary from an approved RDS snapshot. It does not restore an S3 object.
- **S4** is point-in-time recovery. BB3 `restore-drill.sh` currently implements S3 only; BB3 S4 needs a
   separately reviewed PITR implementation. Do not use the EKS `dr-run.sh` for BB3.
- The source may have a primary and replica, or a primary only. A source replica remains attached to the old
   primary after snapshot restore; it is never silently repointed.
- RDS-only completion proves API/configuration/replica topology, not app recovery. App cutover is a separate
   mode with owner approval. T9 requires app-owner confirmation of both endpoints and a successful business
   transaction/readback reference.

### BB3 S3 Step Reference

This table is for the BB3 AWS sandbox runner only. `S3` means snapshot restore; BB3 S4/PITR is not implemented. `P` is the recovery phase, `S` the step, and `G` an approval gate.

Before each `P*-S*` action, `bb3-run.sh` prints a highlighted **What** preview describing the action and an **Expected** result describing its completion evidence. Review these before continuing. The preview is informational; explicit mutation and owner-approval prompts still control whether an action proceeds.

| Step | Action | Completion evidence |
|---|---|---|
| P0-S01 | Discover source DBs, snapshot, and restore targets | Reviewed source/replica selection and deterministic restore targets |
| P0-S02 | Capture source primary/replica baseline before the outage | Checksum-verified original SG sets and configuration |
| P0-S03 | Keep the app/monitor active, attach one run-scoped no-ingress SG to both source DBs, and capture the resulting failure evidence | Both attachments active; real evidence reference saved; original SGs retained in baseline |
| P1-S01-1 | Record impact start T0 from app/monitor evidence | UTC T0 plus evidence reference; Enter defaults to displayed current UTC |
| P1-S01-2 | Record incident declaration T1 and select S3 | T1 defaults to current UTC; edited T1 requires log evidence; reuses P0 run ID |
| P2-S00 | Preview restore request and compare metadata/parameters | Read-only review |
| P2-S01 | Restore primary from selected snapshot | Explicit mutation approval |
| P2-S02 | Wait for restored primary | RDS `available` |
| P2-S03 | Harden and validate restored primary | Baseline/configuration checks |
| P2-S04 | Wait after primary hardening | RDS `available` |
| P2-S05 | Create restored read replica | Explicit mutation approval |
| P2-S06 | Wait for restored replica | RDS `available` |
| P2-S07 | Harden and validate restored replica | Baseline/configuration checks |
| P2-S08 | Wait after replica hardening | RDS `available` |
| P2-S09 | Check both restore targets | Read-only topology/status |
| P3-G0 | Cutover approval | No separate command; approval is collected in the P3-S01/P3-S02 prompts |
| P3-S01 | Verify the P0 no-ingress SG on the old source pair and attest session closure | Both attachments verified; no source SG change or stop is submitted here |
| P3-S02 | Update or verify secret endpoint pair | Matching verified P3-S01 record |
| P3-S03 | Record manual app deployment and service convergence | App owner and one sanitized multiline deployment log; no commit SHA required |
| P4-S01 | App health check connects to restored DB path | **T8** timestamp/evidence; Service RTO is T8-T0 |
| P4-S02 | Successful business transaction and readback | **T9** timestamp/reference; validation time is T9-T8 |
| P4-G4 | Declare service restored | Owner/incident approval; T10 |
| P5 | No BB3 runner step implemented | Collect/package evidence manually |

P0-S03 submits both source SG changes before waiting so their apply intervals overlap. Keep the app and health monitor active so failed new connections are observable; no writer/job pause is required for this fault injection. It waits for both attachments and requires a real app/monitor failure evidence reference; the SG change blocks new connections but does not prove existing sessions are closed. Restore requests use the pinned, checksum-verified P0-S02 baseline, not the live quarantine SG. P3-S01 verifies that same run-scoped quarantine and separately requires session-closure confirmation; it does not submit another SG change.

T8 ends the Service RTO only after the running app passes its DB health check against the restored endpoint. A failed health check leaves T8 pending. T9 is separate business validation; report it even when it adds 5–10 minutes after T8. A failed transaction leaves business validation incomplete, even if Service RTO was met.

### 0. Incident And Identity

Record the incident ID, IC, data owner, app owner, and UTC timestamps. First complete P0-S01 through P0-S03 so the
original SG baseline is captured before the source pair is quarantined. P0-S03 allocates the run ID, keeps the app
and monitor active, and requires a real app/monitor failure reference after both source DBs use the no-ingress SG.
Run P1-S01-1 with the timestamp from that
evidence; Enter accepts the displayed current UTC time. Run P1-S01-2 to record T1, select S3, and declare the same
run ID. T1 defaults to declaration time; an edited/backfilled T1 requires log evidence and cannot precede T0.
Timestamps are UTC ISO-8601 (`YYYY-MM-DDTHH:MM:SSZ`). S4/PITR remains backlog.

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
bash iac/lab/bb3-db/bb3-run.sh S3 --list
bash iac/lab/bb3-db/bb3-run.sh S3 --only P0-S01
bash iac/lab/bb3-db/bb3-run.sh S3 --only P0-S02
bash iac/lab/bb3-db/bb3-run.sh S3 --only P0-S03
bash iac/lab/bb3-db/bb3-run.sh S3 --only P1-S01-1
bash iac/lab/bb3-db/bb3-run.sh S3 --only P1-S01-2
```

The full `bash iac/lab/bb3-db/bb3-run.sh S3` sequence runs P0 discovery, baseline capture,
and quarantine before recording impact time, then runs the RDS recovery stages and waits for
primary/replica availability. Run selected IDs in order with
`--only P0-S01,P0-S02,P0-S03,P1-S01-1,P1-S01-2,P2-S00`. Ctrl+C during a wait prints a
resume command for that wait step.

Run the complete sequence with `bash iac/lab/bb3-db/bb3-run.sh S3`. To run selected checkpoints only,
use the ordered `--only` list above; see `--list` for all IDs. The full sequence waits automatically
for RDS availability. Press Ctrl+C during a wait to stop; the runner prints the current step's resume command.

#### BB3 Runner Ranges

`--from STEP` and `--to STEP` select an inclusive range in the step table above.
Either option may be used alone: `--from` continues through P4-S02, and `--to`
starts at P0-S01. Without either option or `--only`, the runner stops at P2-S09.
Do not combine ranges with `--only`; step-specific arguments such as `--apply`
still require a single `--only` step. All existing approval prompts remain required.
P3-G0, P4-G4, and P5 are not executable step IDs.

```bash
bash iac/lab/bb3-db/bb3-run.sh S3 --from P2-S06 --to P2-S09 --list
bash iac/lab/bb3-db/bb3-run.sh S3 --from P2-S06 --to P2-S09
bash iac/lab/bb3-db/bb3-run.sh S3 --from P4-S01
bash iac/lab/bb3-db/bb3-run.sh S3 --to P0-S02
```

Use `--list` with a range to review its exact steps without running them. A range
does not infer completed steps or skip waiters. Resume at the appropriate waiter
after an accepted mutation, not at the restore/create step. The options in the
Legacy DEV/EKS Reference below belong to a different runner.

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
bash iac/lab/bb3-db/bb3-run.sh S3 --only P0-S02
```

To redisplay the latest captured table later without AWS access:

```bash
bash iac/lab/bb3-db/bb3-run.sh S3 --only P0-S02 --show
```

For a one-off source not saved in the env file, pass the primary and optional replica IDs explicitly. A replica
ID may be omitted only when the source primary has no attached replicas.

Primary with replica, explicit one-off:

```bash
AWS_PROFILE=pa_iam_aws_sandbox AWS_REGION=ap-southeast-1 \
  bash iac/lab/bb3-db/bb3-run.sh S3 --only P0-S02 <source-primary-id> <source-replica-id>
```

Primary only, explicit one-off:

```bash
AWS_PROFILE=pa_iam_aws_sandbox AWS_REGION=ap-southeast-1 \
  bash iac/lab/bb3-db/bb3-run.sh S3 --only P0-S02 <source-primary-id>
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
bash iac/lab/bb3-db/bb3-run.sh S3 --only P2-S00
```

The saved snapshot and target IDs are used when arguments are omitted. Positional IDs remain available for
reviewed overrides.

The helper verifies the latest capture files against the checksum manifest and refuses a source/account/region
mismatch. It compares snapshot-returned metadata and `env`/`app` tags with the captured primary, showing
differences in red. Preview also compares all captured primary parameter records with the live primary group.
Snapshot APIs do not return the 437 parameter values. Preview is read-only and presents available choices; no
tag changes are made until step 4. The helper does not compare source-replica parameters before S3 because S3
restores a primary. If no source replica exists, preview uses the primary as the new replica template. Tables
include populated restore API fields: `MATCH`, `NEW`, and `DIFF - REVIEW`.

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
bash iac/lab/bb3-db/bb3-run.sh S3 --only P2-S01
```

The script rechecks the snapshot and unused target. For each differing non-reserved tag, choose `1` to keep the
captured-primary value or `2` to use the snapshot value. Those selections are applied to the new primary and
replica tags; the source and snapshot are not changed. `Name` is set to the new target ID, `Role` is set to
`primary` for the restored writer, and `dr-restore` records its lifecycle. Any non-tag snapshot metadata
difference then requires typed `ACCEPT-DIFF`. If captured primary parameter values differ from the live group,
the script asks for `USE-CURRENT-PARAMETERS`; this explicitly selects the current group values. Cancel to stop
if historical captured values are required, since the helper cannot recreate old group contents. Finally, it
displays the request and asks `Submit RESTORE? [y/N]`. Enter defaults to No; answer `y` only after reviewing
target, chosen tags, snapshot, parameters, subnet/SGs, class/AZ, retention/window, and private access. This
creates a billable DB.

For a manual status check, inspect both saved targets without pasting identifiers:

```bash
bash iac/lab/bb3-db/bb3-run.sh S3 --only P2-S09
```

The automatic wait step after restore is `P2-S02`; after primary hardening `P2-S04`; after replica creation
`P2-S06`; and after replica hardening `P2-S08`. If interrupted, resume that ID rather than replaying a
restore/create step that may already have been accepted.

In the full run, `P2-S02` waits for the restored primary; `P2-S04` waits after primary hardening;
`P2-S06` waits for the new replica; and `P2-S08` waits after replica hardening. Continue only when status is
`available`. If interrupted, resume the printed wait step, not the restore/create step. If a mutation was
accepted but the command failed, inspect status before resuming; never submit the mutation again under a new
target without reconciliation.

### 5. Harden And Validate Primary

```bash
bash iac/lab/bb3-db/bb3-run.sh S3 --only P2-S03
```

This compares original baseline, current restored settings, and populated `ModifyDBInstance` fields. It also
compares all 437 captured primary parameter API records with the restored primary. Differences are red; if the
expected group name matches but its values differ, the helper stops because it cannot recreate the old group
contents. If a group switch or supported setting change is needed, it asks `Submit APPLY-PARAMETER-GROUP? [y/N]`.
Enter defaults to No. Recheck `available`, all parameter comparisons, parameter group `in-sync`, subnet group,
SG set, private exposure, class, retention and windows before creating the replica.

### 6. Create And Harden Replica (Separate Confirmations)

```bash
bash iac/lab/bb3-db/bb3-run.sh S3 --only P2-S05
```

This step requires the restored primary to be available, baseline-matched, private, and parameter-group
`in-sync`. The table shows only accepted `CreateDBInstanceReadReplica` values. AWS inherits the same-Region
replica's subnet and parameter groups from the restored primary. Enter `y` only after review at the
`Submit CREATE-REPLICA? [y/N]` prompt; Enter cancels.

After the replica is available:

```bash
bash iac/lab/bb3-db/bb3-run.sh S3 --only P2-S07
```

This verifies the new replica is attached to the restored primary and has matching SG/subnet topology, then
compares all captured original-replica parameter API records with the new replica (or the primary template if
the original had no replica) and checks maintenance-window settings. Differences in an already-correct group
stop for review; the helper cannot recreate historical group contents. Replica retention `0` is expected;
do not apply the primary's 7-day retention to it. Record primary-ready and full-topology-ready timestamps
separately.

### Script-Only Endpoint Update: Sandbox Test

This isolated AWS CLI step updates only the BB3 sandbox secret endpoints. It does not change the BB3 application repository, deploy/restart services, or prove business recovery. The one-time SSM tunnel test passed read-only logins on the old primary, restored primary, old replica, and new replica; tunnels are closed. The existing EC2 host, peering, routes, and host-only PostgreSQL ingress remain active until separately approved cleanup.

#### Prerequisites

- Bash, Python 3, AWS CLI v2, and jq. The Python helper and tests use only the standard library.
- Interactive terminal; approved named sandbox profile/account; ignored iac/sandbox.env with ENV=uat and all four DB IDs.
- AWS permissions: STS identity; RDS DescribeDBInstances/ListTagsForResource; Secrets Manager ListSecrets/DescribeSecret/GetSecretValue/PutSecretValue/UpdateSecretVersionStage; and KMS access if required.
- Exported AWS credentials are refused. AWS CLI history must not be enabled. Secret JSON stays in memory; SecretString is passed through stdin, not process arguments or payload files.
- Metadata-only records are stored under Git-ignored evidence/bb3-secret-endpoints/<DR-ID>/ with restrictive permissions. Records contain endpoint/version metadata, never secret values.

Focused checks:

```bash
python3 iac/lab/bb3-db/test-secret-endpoints.py
bash -n iac/lab/bb3-db/secret-endpoints.sh
shellcheck -S warning -x -P automation/scripts iac/lab/bb3-db/secret-endpoints.sh
```

#### Old DB Fence And Failback Constraint

For this BB3 sandbox runner, P0-S03 is the only source security-group mutation. It checks that live SG attachments still match the pinned P0-S02 baseline, attaches one run-scoped no-ingress SG to both selected source DBs, waits for both attachments, and records the app/monitor failure reference. The SG replacement blocks new connections but does not close existing sessions. P3-S01 verifies the same quarantine and separately requires session-closure confirmation before P3-S02; it does not submit another SG change or stop the source DB.

The prior run's read-only SG check found PostgreSQL ingress still permitted the VPC CIDR and SSM tunnel host, so that run's old pair was not confirmed isolated. Do not treat the new P0 workflow as retroactive proof: only a completed P0-S03 record and P3-S01 verification establish the fence for a new run. Standalone RDS stop limitations may still apply to separate, explicitly approved failback actions; see https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_StopInstance.html#USER_StopInstance.Limitations.

Commands for a future run:

```bash
bash iac/lab/bb3-db/bb3-run.sh S3 --only P3-S01
bash iac/lab/bb3-db/bb3-run.sh S3 --only P3-S02 --apply
bash iac/lab/bb3-db/bb3-run.sh S3 --only P3-S03
```

P3-S02 offers automatic AWS CLI update or manual-update verification. Both show the primary/replica host pair; manual mode asks for confirmation that both values were updated, verifies them read-only, and does not write AWS. Any secret-changing apply requires the matching P3-S01 owner-fence record. For failback, run P3-S01 with --failback latest to attest the restored pair is fenced before returning the secret to the original hosts. Release the temporary source quarantine only under the approved failback plan.

P3-S03 offers automatic app deploy (not implemented/tested; selecting it stops without action) or manual deploy confirmation. Manual confirmation captures one sanitized multiline deployment/convergence log, asks for the app owner, and requires confirmation that all expected services/tasks converged. The log is the evidence reference; no separate commit SHA is required. This remains an owner attestation, not an independently executed deploy. P4-S01 app health/T8 and P4-S02 business transaction/readback/T9 follow as separate steps.
#### Current Result

Run DR-20261020-0756-uat-BB3-S3 completed. Preview verified the current DB_HOST/DB_REPLICA_HOST matched the old primary/replica and showed the restored primary/new replica hosts. After exact secret and DR-run confirmation plus UPDATE-ENDPOINTS, version 14bd1175-cb4c-4ba2-9ed6-de521641e891 became AWSCURRENT. Only endpoint keys changed; the password and unrelated fields were verified unchanged. The local journal is evidence/bb3-secret-endpoints/DR-20261020-0756-uat-BB3-S3/cutover.json. No application deployment, fencing, or business E2E was performed.

#### Next: App Owner E2E

Application testing is pending and requires the app owner/operator; do not claim T9 yet. The app owner must review the endpoint pair, deploy/restart using the separately approved application procedure, verify all expected services/tasks converge, then run a successful business transaction/readback against the restored primary and intended replica path. Ask the owner to confirm both displayed endpoints, provide the transaction/reference ID and UTC time, and state pass/fail. Do not request credentials or business payloads. Record sanitized evidence and owner approval; failure, missing reference, or no approval keeps E2E/T9 pending. The BB3 application repository remains untouched by this DR workflow.

#### App E2E Attestation Status

User supplied transaction reference 12345 and selected that both restored endpoints were verified. App-owner name and UTC completion time have not been supplied. Evidence is incomplete; do not record T9 or declare application recovery until the owner and timestamp are recorded. No credentials or business payloads were provided.

#### Secret-Only Failback

Failback uses the completed saved run, displays CURRENT and RETURN TO host values, and requires typed FAILBACK-ENDPOINTS. It merges the saved endpoint pair into the latest secret version so any subsequently rotated password is preserved:

```bash
bash iac/lab/bb3-db/bb3-run.sh S3 --only P3-S02 --failback latest --preview
bash iac/lab/bb3-db/bb3-run.sh S3 --only P3-S02 --failback latest --apply
```

This does not reconcile database writes or deploy/restart apps. No SSM Automation or new Terraform was deployed for the endpoint update.

### 7. Optional App Cutover: Choose One Mode

Only after RDS validation, inventory all writers/readers/jobs, review fencing, and obtain explicit owner/IC approval.
BB3 has no standalone P3-G0 command; approval is collected in the P3-S01/P3-S02 prompts. Select and
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

### 8. App Connectivity T8 And Business Validation T9

After P3-S03 deployment/convergence, run P4-S01:

```bash
bash iac/lab/bb3-db/bb3-run.sh S3 --only P4-S01
```

The app owner confirms the running application has loaded the restored endpoint and passes its application-level DB health check. A direct operator login, RDS `available`, matching configuration, or green deployment alone is not T8. The helper records the UTC T8 timestamp and health-check evidence reference. Service RTO is `T8-T0` and stops at this verified connectivity milestone; provide the actual UTC impact start T0 when prompted.

After the separate business transaction and readback, run P4-S02:

```bash
bash iac/lab/bb3-db/bb3-run.sh S3 --only P4-S02
```

The app owner confirms success and provides a transaction/reference ID. The helper records T9 in UTC. Report `T9-T8` as business validation duration separately from Service RTO. If the app health check fails, T8 is not recorded and the Service RTO clock continues. If the transaction fails after T8, Service RTO may be met but business validation/T9 remains pending or failed. Do not provide credentials or business payloads.

### 9. Failback And Postmortem

#### After P4-S02

Do not restart the full S3 runner: it starts at discovery and fault injection, not failback.
Complete these checkpoints one at a time:

1. **P4-G4, manual:** Review the recorded T8 health check and T9 business transaction/readback.
  The incident approver declares service restored and records their name, UTC T10, and approval reference.
  Resume jobs only under app-owner approval. Missing or failed app evidence blocks this declaration.
2. **P5, manual:** Preserve the current run's journal, baseline/checksums, deployment log, health-check
  evidence/logs reference, transaction ID, and approvals in the approved evidence location. Report
  Service RTO `T8-T0`, business validation `T9-T8`, total elapsed `T9-T0`, and RPO with limitations.
  There is no BB3 `--only P4-G4` or `--only P5` command.
3. **Failback approval, manual:** Obtain a separate approved change window and data-owner decision.
  Writes committed on the restored primary are not copied back by endpoint failback. Reconcile and
  validate those writes, or obtain explicit acceptance of the identified sandbox data loss. Record
  owner, decision, affected interval, and evidence reference. Do not assume the original pair is current.

Keep the original pair quarantined and retain restored DBs/snapshots while these decisions are pending.

#### Failback Checkpoints

The following FB labels are worksheet checkpoints, not new runner step IDs. Use the explicit completed
cutover run ID instead of `latest`, which could select another drill. Set it locally before the commands:

```bash
DR_ID='{{COMPLETED_CUTOVER_DR_ID}}'
```

1. **FB-01: Review return endpoints, read-only.** Verify the saved run, selected secret, current restored
  primary/replica hosts, and original return hosts. This does not deploy or reconcile data:

  ```bash
  bash iac/lab/bb3-db/bb3-run.sh S3 --only P3-S02 --failback "$DR_ID" --preview
  ```

2. **FB-02: Drain clients and fence the restored pair.** App owner pauses/drains writers, readers,
  workers, and jobs before this separate failback outage. Verify isolation and existing-session closure
  on the restored pair before changing endpoints. Keep the original pair quarantined meanwhile.

  **Current replica-pair blocker:** `P3-S01 --failback` expects an attached
  `failback-network-fence.json` for a restored primary with a replica; it does not currently create
  that pair's failback quarantine. Stop here until this path is implemented/tested or a separately
  reviewed isolation procedure and matching verified journal are provided. Do not fabricate a journal,
  stop a replica-backed primary, or bypass the fence gate. The verification command is:

  ```bash
  bash iac/lab/bb3-db/bb3-run.sh S3 --only P3-S01 --failback "$DR_ID"
  ```

3. **FB-03: Switch both endpoint keys, explicit approval.** Only after FB-02 passes, review the plan
  again and type `FAILBACK-ENDPOINTS` when approved. Credentials and unrelated fields stay unchanged:

  ```bash
  bash iac/lab/bb3-db/bb3-run.sh S3 --only P3-S02 --failback "$DR_ID" --apply
  ```

4. **FB-04: Release the original source quarantine, explicit approval.** After the endpoint failback
  journal is complete, recheck that the restored pair remains isolated and its sessions are closed.
  This command restores the saved original SG sets, verifies them, and deletes the temporary source
  quarantine SG after typed `RELEASE-SOURCE-QUARANTINE`. The restored pair stays fenced:

  ```bash
  bash iac/lab/bb3-db/bb3-run.sh S3 --only P3-S01 --failback "$DR_ID" --release-quarantine
  ```

5. **FB-05: Redeploy and validate the app, manual.** The app owner deploys/restarts using the approved
  application procedure so tasks load the original endpoints. Confirm all expected services converge,
  then record an app DB health check and a successful business transaction/readback on the original
  primary and intended replica path. Record owner, UTC times, sanitized deployment/health logs, and
  transaction reference. A complete endpoint journal alone is not completed application failback.
  Do not rerun P4-S01/P4-S02 to overwrite the recovery T8/T9; these helpers have no failback mode.
6. **FB-06: Declare failback complete, manual.** Obtain incident/app-owner sign-off, record completion
  time and evidence, then resume approved jobs. If validation fails, keep jobs paused and use the
  separately approved contingency plan; do not un-fence both database pairs.
7. **FB-07: Retain, then clean up under separate approval.** Preserve evidence and restored DBs/snapshots
  until reconciliation and retention decisions are signed off. Plan billable-resource cleanup through
  the approved IaC/ownership process, review the saved plan, and obtain approval before applying it.
  Do not delete the restored pair or remaining quarantine SG merely because endpoint failback succeeded.

Record T0/T1/T2/T4/T5/T6/T7/T9/T10, snapshot reference and age, baseline and diff tables, approvals, old/new
secret version IDs only, deployed SHA, task convergence, transaction reference, and final evidence hashes.
Calculate Service RTO as T8-T0; report business validation T9-T8 and total elapsed T9-T0 separately, along with replica/topology recovery. Postmortem: incident cause,
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

> > bash iac/local.sh doctor

The required drtest-pg-restored container isn’t in the running list. First check whether it’s stopped or missing:
drtest-pg-restored Exited (0) 6 hours ago

> > bash iac/local.sh db restored start
> > Review the displayed plan and type APPLY when prompted. Send me the result before the next step. >>> Verified drtest-pg-restored running=true; data volume preserved.

> > > bash iac/local.sh ready
> > > Engine: colima-dr-framework | linux/aarch64 | 28.4.0
> > > Context: colima-dr-framework
> > > deployment "app-d" successfully rolled out
> > > deployment "app-e" successfully rolled out
> > > deployment "reloader-alert-sink" successfully rolled out

> > > bash iac/local.sh dr S3 --dry-run

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
bash automation/scripts/dr-env-discover.sh dev \
  --profile dr-dev --region eu-west-1 \
  --db <current-primary-id> \
  --cluster <DEV-EKS-cluster> --context dr-dev \
  --namespace app --secret <app-db-secret> \
  --kubeconfig "$HOME/.kube/dr-dev.config" --print
```

If the preview is correct, run the same command without `--print` to write the file. If `env/dev.env` already exists, discovery refuses to overwrite it; use `--force` only after reviewing it, since the script saves a `.bak`.

Discovery can usually fill the account/profile, primary ID and RDS properties, tags, evidence bucket, matching quarantine security group, EKS name/context, and Secret/key names. It leaves a TODO or note when it can’t find a unique value.

Review and fill missing values such as the app health URLs, tables to verify, incident ticket, and any cluster/Secret selection it could not resolve. Keep `DB_SUBNET_GROUP`, `DB_SG`, `DB_PARAM_GROUP`, and `DB_INSTANCE_CLASS` empty unless an approved override is needed: restore settings are captured from the live source baseline. Don’t put passwords in the env file.

With the current `SECRET_MODE=k8s`, app credentials must be available through the configured Kubernetes Secret for automated login checks. `MASTER_SECRET_ID` is an __identifier__ needed by helpers that use master credentials, such as fencing or `fix-password`; if the master password exists only in an external note, the scripts cannot retrieve it. Have the DBA perform those steps through the approved secure process, or provision a secure secret source. Never paste the password into the env file.

**Check before running**
Source the generated file and make both checks pass:

```bash
source env/dev.env
bash automation/scripts/dr-env-check.sh S4   # use S3 for snapshot restore
bash automation/scripts/dr-preflight.sh restore
```

Then inspect the runner’s steps and commands without making changes:

```bash
bash automation/scripts/dr-run.sh S4 --list
bash automation/scripts/dr-run.sh S4 --dry-run
```

For this DEV profile, use `SECRET_MODE=k8s`, confirm the Secret host keys are correct, and verify Reloader plus all database consumers. The preflight reports consumers that need a manual restart.

**Run the recovery**
For a time-specific recovery from automated backups:

```bash
bash automation/scripts/dr-run.sh S4
```

For a snapshot restore:

```bash
bash automation/scripts/dr-run.sh S3
```

The runner pauses for incident inputs and approval gates. S4 needs the bad-change time, a restore time inside the available PITR window, and a decision between full cutover and side-instance repair. S3 prompts for the snapshot; the newest automated snapshot is the default. Review the restore plan before approving the restore. Both paths then wait for the new instance, harden it against the captured baseline, validate, verify app access, and require cutover approval before changing the endpoint. The cutover updates every configured host key, rolls annotated workloads via Reloader, and checks stale consumers.

If you need to step away, note the printed `DR_ID` and resume that run rather than starting another:

```bash
bash automation/scripts/dr-run.sh S4 --resume <DR_ID>
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
bash automation/scripts/dr-env-discover.sh dev --profile YOUR_DEV_PROFILE --region ap-southeast-1
# Review env/dev.env before sourcing it
source env/dev.env
bash automation/scripts/dr-env-check.sh S3
bash automation/scripts/dr-run.sh S3 --list
bash automation/scripts/dr-run.sh S3 --dry-run
bash automation/scripts/dr-run.sh S3
```

Here are the options for the shared **S3/S4 step runner** in `dr-run.sh`.

**Run it**

```bash
# Local Moto/LocalStack
bash iac/local.sh dr S3 [options]

# Real AWS, after sourcing the reviewed environment file
source env/dev.env
bash automation/scripts/dr-run.sh S3 [options]
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

__Inputs__
For S3, the runner may ask for `SNAPSHOT_ID`, `RESTORED_DB`, `OLD_DB`, `T0_AT`, and the end-to-end test reference. For S4, it may ask for `BAD_TS` or `RESTORE_TS`, `RESTORE_MODE` (`A` or `B`), and the same DB/test-reference inputs. You can export inputs beforehand to skip their prompts; accepted inputs are saved for resume.

Examples:

```bash
bash iac/local.sh dr S3 --list
bash iac/local.sh dr S3 --dry-run
bash iac/local.sh dr S3 --only P0-S01
bash iac/local.sh dr S3 --to P2-S05
bash iac/local.sh dr S3 --resume DR-20261014-0607-local-S3
```

`DR_RUN_GATES=auto` and `DR_RUN_AUTO_NO=...` are __local test-only__ controls, not real-AWS run options.

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
bash iac/local.sh doctor
bash iac/local.sh ready
bash iac/local.sh dr S3 --list
bash iac/local.sh dr S3 --dry-run
```

The local lab is Terraform-managed. Don’t use `up.sh` or `down.sh` to reset it; they are legacy scripts. A clean baseline requires a reviewed reset/rebuild plan, and evidence should be preserved.

**What the S3 steps do**

1. __P0 preflight:__ Check required variables, tools, local AWS identity and Kubernetes context; then check the source DB, snapshots, Secret, and Reloader. `OLD_DB` is the current source; `RESTORED_DB` is a new target.
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