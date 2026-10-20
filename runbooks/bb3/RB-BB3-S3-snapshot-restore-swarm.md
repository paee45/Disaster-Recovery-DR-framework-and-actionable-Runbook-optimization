# RB-BB3-S3 - RDS Snapshot Restore and Docker Swarm Cutover

| Field | Value |
|---|---|
| Runbook ID / version | RB-BB3-S3 / v0.1-draft |
| Service | BB3 RDS PostgreSQL and the `beepbeep` Docker Swarm stack |
| Environments | dev, uat, prod; separate approved account, secret and SSH host per environment |
| Owner / review / approval | `{{SRE_OWNER}}` / SRE and application owner / CTO for production data loss |
| Recovery | New RDS instance from a snapshot -> AWS Secrets Manager endpoint update -> deployment from `bb3-infrastructure` |
| Targets | RPO 24 hours; RTO 30 minutes, including approvals, deployment and application verification |
| Status | Separate BB3 procedure; NOT yet exercised against BB3 or real AWS sandbox |
| Automation | Existing RDS request builders and SSM document are reusable; the S3/S4 step runner remains EKS-only |

## 1. Scope And Readiness

S3 here means scenario S3, **snapshot restore**, not an S3 object-storage restore.
Use an RDS snapshot or an approved AWS Backup recovery point. The restore commands below are for an
RDS DB snapshot; an AWS Backup recovery point needs its reviewed AWS Backup restore procedure first.
Use PITR instead when an approved point-in-time recovery meets the incident needs better.

This runbook replaces the Kubernetes application steps, not the database restore controls. Do not run
`dr-run.sh S3`, `dr-secret-cutover.sh apply`, ESO, Reloader or Kubernetes rollout commands for BB3.
Those scripts still require the EKS workflow and are not a Swarm runner.

The local exercises demonstrated the restore orchestration, endpoint change, owner gates and failback.
They did **not** test BB3, Docker Swarm, real RDS restore speed, replication, or historical snapshot data.
The local PostgreSQL fixtures are independent persistent databases, not actual snapshot clones.
Run `DR-20261018-1801-local-S3` recorded owner-attested recovery using reference `12345`, then failback
`DR-local-failback-20261019041135-12495` returned the endpoint to the original fixture. RTO was
569.11 minutes including an overnight pause; synthetic RPO was 98,898.2 seconds. Both targets were missed.
The referenced business evidence was not independently inspected. Do not use these as sandbox certification.

Before a real drill, resolve these gates:

- Verify the approved AWS account/profile/region, RDS source, snapshot, network and all consumer services.
- Confirm the exact endpoint keys in the mixed Secrets Manager JSON with the application owner, without
  giving the DR operator access to its credential payload. Record the secret version ID, not its value.
- Review the deployment script at an approved commit pushed to `main`. Confirm how it reads Secrets Manager,
  replaces Docker secrets/configuration and redeploys **all** consumers, workers and scheduled tasks.
  Updating AWS Secrets Manager alone does not update existing Swarm tasks or immutable Docker secrets.
- Confirm environment-specific SSH host identity, checked host key, repository path and stack ownership.
  Real hostnames/account IDs belong in ignored environment configuration, not this runbook.
- Review deployment output for credential leakage before enabling automated capture. Do not collect secret
  payloads, rendered credential files or raw application logs containing sensitive data.
- Have a reviewed RDS baseline and restore/hardening requests, approved fencing, data acceptance, app-owner
  business test and failback/data-reconciliation plan. Stop if any item is unknown.

## 2. Roles And Execution Choices

### Scope And App Cutover Modes

The default safe drill is RDS-only: provision/restore the isolated sandbox DBs and validate API configuration,
parameter groups, network and replica relationships. App cutover is a separate optional phase. Do not connect
to BB3 real environments or change their databases. No local Swarm fixture is currently provided. The DB stack
is [iac/lab/bb3-db](../../iac/lab/bb3-db/README.md); the interactive AWS request flow is
[`restore-drill.sh`](../../iac/lab/bb3-db/restore-drill.sh).

Before app cutover, the incident commander and app owner select exactly one mode and record it. Both modes
update the same existing mixed secret fields; neither may fetch or print the credential payload:

| Mode | Secret change | Deployment/restart |
|---|---|---|
| `manual` | Authorized custodian changes only `DB_HOST` and `DB_REPLICA_HOST`; preserves `DB_NAME`, `DB_USER`, `DB_PASSWORD`, and unrelated keys; records old/new version IDs | App owner connects to the approved EC2 host, verifies the approved `main` SHA, and runs `scripts/deploy.sh <dev|uat|prod>` or the explicitly reviewed restart procedure |
| `ssh-script` | Allowed only if the reviewed GitHub script is verified to update both endpoint keys server-side; otherwise the custodian must update the secret manually first | App owner approves SSH; script verifies a clean `main`, fast-forward pulls, pins the approved SHA, runs `scripts/deploy.sh <dev|uat|prod>`, and verifies Swarm convergence. Dev/uat only until production approval |

The `bb3-infrastructure` repository is not present in this workspace. Its deployment script must be reviewed at
the approved SHA before enabling `ssh-script`; do not assume it updates Secrets Manager. Record the selected
mode, approval, host, secret version IDs, commit SHA and result.

Keep application-owner steps as explicit prompts/gates in the incident worksheet:

| Gate / step | Prompt to the app owner | If not performed today |
|---|---|---|
| P2-S02 | Have all writer/reader services and jobs been identified? Record owner and inventory reference | PENDING; the DB-copy test can continue, but no application cutover |
| P3-G0 | Do you approve the exact target, fencing procedure, secret update and deployment? Record GO/NO and owner | PENDING/NO blocks all cutover actions |
| P3-S02 | Did the selected mode update both `DB_HOST` and `DB_REPLICA_HOST` to the reviewed primary/replica endpoints? Record target IDs and old/new secret version IDs | PENDING until confirmed; no T6 |
| P3-S03 | Did the selected manual or SSH mode deploy the approved commit and converge all expected Swarm services/tasks? Record mode, SHA and result | PENDING until verified; no T7 |
| P4-S02 | Did the app owner confirm both displayed DB targets, run a successful business transaction/readback, record its transaction/reference number and evidence, and approve GO? | PENDING until confirmed; no T9 or business-recovery claim |

The session result is **RDS restore/API validation only**, not end-to-end DR certification. Do not fabricate
application answers to finish the tracker, and do not report business RTO until an actual T9 exists.

### Primary And Read Replica Behavior

- Neither the source with attached read replicas nor a read replica can be stopped. Stopping the replica first
  is not a supported workaround. Do not delete/promote a replica just to make the local `FENCE=stop` path work.
- A snapshot restore creates a new standalone DB. The existing replica stays attached to the old source;
  it is not moved, overwritten or made a replica of the restored DB. Verify these relationships by RDS API.
- If recovery later cuts over to the restored DB, the old replica will still contain old-source data. Review
  every read endpoint too; otherwise the application can mix new-primary writes with stale old-replica reads.
- Rebuild a new replica from the recovered primary as separately approved normalization. Do not assume an
  existing physical replica can be repointed to a different snapshot-restored source.
- Logical corruption is normally replicated too. Preserve the old source/replica for investigation and data-owner
  review; do not reuse them as trusted recovery copies or automatically wipe them. Retire them only through a
  separately approved retention/reconciliation and disposal change.
- `switchover-read-replica` is an Oracle Data Guard operation, not a PostgreSQL switchover command. PostgreSQL
  replica promotion is a different scenario requiring writer drain, lag/data-loss review, fencing and new replicas;
  promotion is not a reversible or unconditional zero-data-loss operation. Keep that separate from S3 restore.
- For today's copy test, leave source and replica running and unchanged. A later real cutover needs an approved
  writer-drain/isolation procedure covering existing sessions; security-group metadata alone is not proof.

AWS references: [stop limitations](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_StopInstance.html#USER_StopInstance.Limitations)
and [read-replica behavior](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_ReadRepl.html).

| Role | Responsibility |
|---|---|
| Incident commander | Scope, approvals, communications, stop/go decisions |
| DR operator | RDS API restore/configuration, endpoint coordination, evidence; no DB credentials or SQL |
| Data owner / DBA | Snapshot/data-loss acceptance; reconciliation through separately authorized access |
| Application/platform owner | Mixed-secret custody, deploy script review, Swarm deployment and business E2E |

Choose and record one application cutover mode before P3-G0:

| Mode | Secrets Manager endpoint update | Swarm deploy/restart |
|---|---|---|
| `manual` | Authorized custodian updates only `DB_HOST` and `DB_REPLICA_HOST` in the existing mixed secret, preserving `DB_NAME`, `DB_USER`, `DB_PASSWORD` and unrelated keys; records previous/new version IDs | App owner connects to the approved environment EC2 host, verifies the approved `main` commit, then runs `scripts/deploy.sh <dev|uat|prod>` or the reviewed service restart procedure; records deployed SHA and convergence |
| `ssh-script` | Only if the reviewed GitHub deployment script is verified to update both endpoint keys server-side. Otherwise the custodian updates the secret manually first. The operator receives version/endpoint metadata only, never the payload | App owner approves SSH; script verifies clean `main`, fast-forward pulls, checks the exact approved SHA, then runs `scripts/deploy.sh <dev|uat|prod>` and checks every Swarm service. Dev/uat only until production is separately approved |

The `bb3-infrastructure` GitHub repository is not present in this workspace. Before enabling `ssh-script`, review its actual implementation at the approved commit and verify whether it updates the mixed secret or only deploys from its current value. Do not claim script-assisted secret updates work until that repository change is reviewed and tested. Record `APP_CUTOVER_MODE=manual|ssh-script`, the approval, host, commit SHA and result.

**Production deployment is manual.** The owner opens SSH and obtains root privileges interactively before
accessing the `projects` directory. Never pipe a password, automate `sudo su`, disable host-key checks,
or route passwords through an assistant. SSH access and deployment are privileged application-owner
operations, not an extension of the credential-restricted DR operator role.

## 3. Session Configuration

Keep real values in an ignored environment file. Do not paste credentials into this block or evidence.
Use a separate sandbox-only configuration during testing; do not point it at BB3 real environments.

```bash
export DR_ENV=dev
export AWS_PROFILE='{{APPROVED_PROFILE}}'
export AWS_REGION='{{APPROVED_REGION}}'
export ACCOUNT_ID='{{APPROVED_ACCOUNT_ID}}'
export OLD_DB='{{SOURCE_DB_ID}}'
export RESTORED_DB='{{NEW_UNIQUE_DB_ID}}'
export SNAPSHOT_ID='{{APPROVED_RDS_SNAPSHOT_ID}}'
export SECRET_ID='{{BB3_APP_SECRET_ID}}'
export APP_CUTOVER_MODE='{{manual|ssh-script}}'
export SWARM_SSH_HOST='{{ENVIRONMENT_SSH_HOST}}'
export DEPLOY_COMMIT_SHA='{{APPROVED_FULL_MAIN_COMMIT_SHA}}'
export DR_ID="DR-$(date -u +%Y%m%d-%H%M)-${DR_ENV}-BB3-S3"
export DR_EVIDENCE_DIR="evidence/$DR_ID"
mkdir -p "$DR_EVIDENCE_DIR/aws" "$DR_EVIDENCE_DIR/app" "$DR_EVIDENCE_DIR/approvals"
aws --profile "$AWS_PROFILE" --region "$AWS_REGION" sts get-caller-identity
```

Check the returned account against `ACCOUNT_ID` and the approved environment before any mutation.
Production uses approved SSO/assumed-role authentication, not exported long-lived access keys.
Do not source EKS-specific session setup to bypass a missing Swarm guard. Until a dedicated runner is
implemented, the owner records UTC markers and approvals in the incident worksheet and evidence files.

## 4. Restore And Cutover

| ID | Step | Owner | Budget | Expected / verify; stop condition |
|---|---|---|---|---|
| P1-S01 | Record T0 (first application error), T1 (incident opened), environment, source and new target | IC / operator | 1 min | UTC times, account/profile/region verified; no existing target overwritten |
| P1-S02 | List available snapshots, inspect snapshot source/time/encryption and record `RPO_SNAPSHOT` | Operator | 1 min | Approved snapshot belongs to the intended source; age and potential lost writes visible |
| P1-G1 | Data owner accepts the snapshot and loss window, including writes until fencing; record `DATA_OWNER`, `DATA_ACCEPTANCE_REF`, GO and T2 | Data owner / IC | 1 min | Explicit acceptance; production CTO approval; NO blocks restore |
| P2-S00 | Review the baseline-driven restore request and post-restore hardening plan | Operator / platform owner | Included below | All SGs/subnets/parameter groups, tags, encryption, storage, monitoring, HA and retention accounted for |
| P2-S01 | Issue the reviewed restore request; record T4 | Operator | 12 min total restore | Fresh target ID; request and response metadata saved |
| P2-S02 | Inventory all BB3 DB consumers and pause write jobs through the application owner while RDS restores | App owner | Parallel | All relevant services/jobs recorded; no hidden writer left unaccounted for |
| P2-S03 | Wait for RDS `available`; record T5 | Operator | Included in restore | Available is infrastructure status only, not app recovery |
| P2-S04 | Apply approved hardening; compare every required API setting/tag with the baseline, retention at least 7 days | Operator | 4 min | No unexpected drift; record accepted exceptions; no SQL/password fetch |
| P3-G0 | Confirm validated target, secret/deploy modes, approved deployment commit and fencing plan; approve cutover | IC / app owner | Included below | No secret mutation or deployment before GO |
| P3-S01 | Fence the original DB against all application writers, with a confirmed stop when eligible | Platform owner | 5 min total cutover | Stop is confirmed before app-owner E2E; an unreachable endpoint alone is not proof |
| P3-S02 | Use `APP_CUTOVER_MODE` to set `DB_HOST` to the restored primary and `DB_REPLICA_HOST` to its replica; record old/new secret version IDs, target IDs and T6 | Secret custodian / app owner | Included in cutover | Only endpoint keys change; `DB_NAME`, `DB_USER`, `DB_PASSWORD` and unrelated keys remain unchanged; no payload returned to DR operator |
| P3-S03 | Use the selected manual or reviewed SSH-script mode to deploy/restart the approved `main` SHA; verify all expected Swarm tasks converge; record T7 | App owner | Included in cutover | Correct host/account, approved commit and deploy exit 0; not just any Running task |
| P4-S01 | Confirm original remains fenced, target available and deployment no longer uses the prior endpoint; inspect service health/restarts | App owner / operator | 1 min | Old tasks drained, no stale consumers; jobs remain paused until safe |
| P4-S02 | App owner confirms `yes/no` for displayed primary and replica targets, runs the approved business transaction/readback, records transaction number/reference and evidence, supplies `APP_OWNER`/`E2E_REF`, then approves GO | App owner | 3 min | Successful transaction on restored primary plus intended read path on restored replica; blank/no or failed proof cannot record T9 |
| P4-G4 | Record T9 only after that attestation; declare restored, record T10 and resume approved jobs | IC / app owner | 1 min | Approver matches named app owner; application proof is separate from API status |
| P5-S01 | Collect sanitized evidence and calculate RTO/RPO; record limitations and outstanding normalization | Operator | 1 min | T9-T0 includes waits; target misses retained, not adjusted away |

### RDS API Commands

Use the existing [request builders](../../automation/scripts/rds-requests.jq) and
[configuration-parity procedure](../common/CP-03-restored-instance-config-parity.md) as the database specification.
The platform owner prepares `aws/restore-request.json` and `aws/harden-request.json` from an approved baseline;
do not replace that work with CLI defaults. Existing `dr-restore.sh` is not yet a Kubernetes-free BB3 runner.
If the original is lost, use a previously reviewed baseline, not guessed settings.

Current snapshot and PITR restore inputs include `BackupRetentionPeriod` and `PreferredBackupWindow`.
Supply their captured values (this baseline: 7-day writer retention), along with the supported network,
parameter-group, class, storage and other restore fields. Host AWS CLI 2.38.1 supports both backup inputs.
The shared request builder checks each operation's local CLI input model; on older CLIs it reports and defers
only unsupported backup inputs to hardening. Always validate the final configuration after restore.

```bash
aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-snapshots \
  --db-instance-identifier "$OLD_DB" --query 'DBSnapshots[].{ID:DBSnapshotIdentifier,At:SnapshotCreateTime,Status:Status,Encrypted:Encrypted}'
aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds restore-db-instance-from-db-snapshot \
  --cli-input-json "file://$DR_EVIDENCE_DIR/aws/restore-request.json"
aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds wait db-instance-available \
  --db-instance-identifier "$RESTORED_DB"
aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds modify-db-instance \
  --cli-input-json "file://$DR_EVIDENCE_DIR/aws/harden-request.json"
aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds wait db-instance-available \
  --db-instance-identifier "$RESTORED_DB"
aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-instances \
  --db-instance-identifier "$RESTORED_DB" > "$DR_EVIDENCE_DIR/aws/restored-instance.json"
```

Fencing stop is supported only for eligible standalone RDS PostgreSQL: no cluster membership, replica source,
or attached read replicas. Check topology first. If BB3 has replicas/HA constraints that prevent stop, obtain a
separately reviewed isolation procedure and proof covering existing sessions and every writer. Do not detach or
delete replicas ad hoc, use SQL with operator credentials, or treat security-group attachment alone as proof.
Real RDS automatically restarts a stopped instance after seven days; monitor and maintain isolation.

```bash
aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds stop-db-instance --db-instance-identifier "$OLD_DB"
aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds wait db-instance-stopped --db-instance-identifier "$OLD_DB"
aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-instances \
  --db-instance-identifier "$OLD_DB" --query 'DBInstances[0].DBInstanceStatus'
```

### Secrets Manager: Manual Or SSM

Manual: the authorized custodian updates only the approved endpoint fields in the existing mixed secret,
preserving credentials and other configuration. Custodian verifies the intended host/port and records old/new
version IDs and an approval reference. Operator can inspect version metadata with `describe-secret`, not `get-secret-value`.

Script-assisted: use [DR-UpdateDbSecretEndpoint](../../automation/ssm/DR-UpdateDbSecretEndpoint.yaml) only after
it is registered and reviewed in the selected account. Its current implementation updates JSON `host`, `port`
and an existing `dbInstanceIdentifier`; it does NOT support arbitrary BB3 key names. If BB3 differs, STOP and
adapt/review/test the document before use. Do not add unused `host` keys and assume the application changed.

Use an approved pinned document version and a narrowly scoped service role: access only the intended secret,
RDS metadata and required KMS key. Operator needs execution/status permissions and narrowly scoped `iam:PassRole`,
not `secretsmanager:GetSecretValue`, document editing, role editing, or the ability to assume that service role.
The script must never return secret values or include them in exceptions/logs. Account-specific IAM and document
registration must be reviewed IaC, not an ad hoc real-account installation.

```bash
export SSM_DOCUMENT_VERSION='{{APPROVED_NUMERIC_DOCUMENT_VERSION}}'
export SSM_AUTOMATION_ROLE='{{APPROVED_SERVICE_ROLE_ARN}}'
SSM_PARAMETERS="$(jq -nc --arg role "$SSM_AUTOMATION_ROLE" --arg secret "$SECRET_ID" \
  --arg db "$RESTORED_DB" --arg id "$DR_ID" \
  '{AutomationAssumeRole:[$role],SecretId:[$secret],DbInstanceId:[$db],DrId:[$id]}')"
aws --profile "$AWS_PROFILE" --region "$AWS_REGION" ssm start-automation-execution \
  --document-name DR-UpdateDbSecretEndpoint --document-version "$SSM_DOCUMENT_VERSION" \
  --parameters "$SSM_PARAMETERS" > "$DR_EVIDENCE_DIR/aws/secret-update-execution.json"
SSM_EXECUTION_ID="$(jq -r .AutomationExecutionId "$DR_EVIDENCE_DIR/aws/secret-update-execution.json")"
aws --profile "$AWS_PROFILE" --region "$AWS_REGION" ssm get-automation-execution \
  --automation-execution-id "$SSM_EXECUTION_ID" \
  --query 'AutomationExecution.{Status:AutomationExecutionStatus,Outputs:Outputs}'
```

Poll status until `Success`, then record version IDs and endpoint metadata. Failed/timed-out/cancelled/unknown
executions block deployment. Reconcile actual current version before retrying an interrupted update. This is
not automatic rollback: do not change version stages after restored-side writes without data-owner review.

### Deploy: Manual Or SSH-Assisted

Before either path: deployment configuration is approved and pushed to `main`; deployment must consume the new
secret version, not a cached value. Record the approved full commit SHA, actual deployed SHA and service inventory.

Manual: use the configured environment host (dev host, uat host, or production host respectively). For production,
obtain root interactively first as described above. In that authorized shell:

```bash
ssh -o StrictHostKeyChecking=yes -- "$SWARM_SSH_HOST"
```

Inside SSH, set `DR_ENV` and `DEPLOY_COMMIT_SHA` to the approved non-secret values from the incident worksheet.
Then run from the appropriate user's home directory (production: root's projects directory):

```bash
cd projects/bb3-infrastructure
test "$(git branch --show-current)" = main
test -z "$(git status --porcelain)"
git pull --ff-only origin main
test "$(git rev-parse HEAD)" = "$DEPLOY_COMMIT_SHA"
scripts/deploy.sh "$DR_ENV"
docker stack ps --no-trunc beepbeep
docker service ls
```

Run each check successfully before the next command; stop on a dirty checkout, wrong branch, different SHA,
failed pull or nonzero deployment. Do not reset local changes or blindly deploy the latest unapproved commit.

SSH-assisted shell, **dev/uat only**, after approval. It assumes the reviewed repository path below and a trusted
SSH host key already installed. It fails rather than prompting for passwords or accepting unknown host keys.
The repository/deploy script is not included in this workspace, so this path still needs a sandbox test.

```bash
[[ "$DR_ENV" == dev || "$DR_ENV" == uat ]] || { echo 'Production deployment is manual'; exit 2; }
[[ "$DEPLOY_COMMIT_SHA" =~ ^[0-9a-fA-F]{40}$ ]] || { echo 'Approved full commit SHA required'; exit 2; }
read -r -p 'Type GO to deploy the approved main commit on the configured Swarm host: ' DEPLOY_GO
[[ "$DEPLOY_GO" == GO ]] || exit 2
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -- "$SWARM_SSH_HOST" \
  bash -s -- "$DR_ENV" "$DEPLOY_COMMIT_SHA" <<'REMOTE'
set -euo pipefail
environment="$1"; approved_commit="$2"
[[ "$environment" == dev || "$environment" == uat ]]
[[ "$approved_commit" =~ ^[0-9a-fA-F]{40}$ ]]
cd "$HOME/projects/bb3-infrastructure"
[[ "$(git branch --show-current)" == main ]]
[[ -z "$(git status --porcelain)" ]]
git pull --ff-only origin main
[[ "$(git rev-parse HEAD)" == "$approved_commit" ]]
scripts/deploy.sh "$environment"
docker stack ps --no-trunc beepbeep
docker service ls
REMOTE
```

Compare expected service replicas with actual replicas, inspect update state and failed/restarting tasks, and
wait for convergence. `docker stack ps ... | grep Running` alone is insufficient: it can hide failed tasks or
show old tasks during an incomplete deployment. The app owner may inspect a specific service's logs privately:

```bash
docker service logs --timestamps --since 1m beepbeep_bb3-promos 2>&1 | sort
```

Logs and Running tasks do not prove which DB served a transaction. App owner must confirm the displayed restored
DB and provide evidence of connectivity and a successful business transaction there. Keep credentials out of that proof.

## 5. Abort, Failback And Normalization

### Rebuild And Validate Recovery Replicas

Include a fresh read replica of the restored DB in this sandbox drill, not just the initial source's replica.
Begin its reviewed Terraform provisioning once the restored primary is available, hardened and validated.
Use a new recovery-specific identifier and a separate create-only saved-plan approval. Do not change the
original replica's `replicate_source_db`, delete the original replica or apply a replacement of that resource.
Do not count Terraform plan generation as provisioning or replica `available` as business-data proof.

Validate the following for restored primary and new replica, recording every accepted difference:

- Engine version/parameter-group family and approved user parameters, including `wal_keep_size` and
  `max_connections` when overridden. Inspect values and `ParameterApplyStatus`, not just the group name.
  Share an approved custom group when appropriate; size-dependent settings must suit each instance class.
  Do not blindly copy production connection/memory limits onto a smaller sandbox replica or set WAL values
  without reviewing retained-WAL storage, replication slots and workload needs.
- Every security group, subnet group and AZ placement, private exposure, port, storage type/size/autoscaling,
  encryption/KMS, backup policy, maintenance settings, log exports, monitoring and relevant tags. Compare the
  replica against its approved replica baseline; it need not match every writer-only setting.
- RDS source association must name the **restored** primary for the new replica and the **old** primary for the
  original replica. Both must be available and replication status healthy. Inspect `ReplicaLag` over time against
  an approved threshold; missing metrics are not zero lag. Idle PostgreSQL can report lag without new writes,
  so assess engine behavior and metrics together. Only the app/data owner can provide independent data checks.

Record replica-create start/end and **full-topology recovery time** alongside primary availability and business
RTO (T9-T0). If service recovery depends on read replicas, its T9 must wait for their readiness and app-owner E2E.
Otherwise report business recovery and redundancy restoration separately; do not silently exclude replica time.
Today's RDS-only session has no app-owner E2E/T9 and cannot certify business RTO or data correctness.

AWS reference: [promotion prerequisites and behavior](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_ReadRepl.Promote.html)
and [Oracle-only switchover command](https://docs.aws.amazon.com/cli/latest/reference/rds/switchover-read-replica.html).

Failback is a separate approved change, not an automatic consequence of a failed deploy.

| ID | Step | Owner | Expected / stop condition |
|---|---|---|---|
| FB-G1 | Account for restored-side writes; reconcile and obtain data-owner sign-off before routing back | Data owner / IC | No production waiver. `ACCEPT_LOCAL_DATA_LOSS` was local-fixture-only and is not valid for BB3 or sandbox business data |
| FB-S01 | Prepare original/replacement DB and reviewed restart/isolation plan | Platform owner | Correct target available and approved; never revive an unsafe original simply to undo an endpoint change |
| FB-G2 | Approve the exact endpoint/version change and redeployment | IC / app owner | Recorded GO, actor and data policy |
| FB-S02 | Use the selected manual/SSM update targeting the approved failback DB, then the selected manual/SSH deployment | Custodian / app owner | New version and deployed SHA recorded; same credential and production restrictions |
| FB-S03 | App owner confirms target with yes/no, records evidence and GO after business verification | App owner | Old/restored tasks drained; business transaction uses the failback DB |
| FB-S04 | Only then approve stopping/quarantining unused restored DB; retain snapshots/data and rollback evidence | Platform owner | No automated deletion or `--skip-final-snapshot`; preserve writes until retention/reconciliation approved |
| FB-S05 | Normalize backups, HA/replicas, monitoring, rotation and IaC; restore approved schedules | Platform owner | Tracked follow-up change, no unexpected drift |

## 6. Evidence And Closure

Keep T0/T1/T2/T4/T5/T6/T7/T9/T10 and fencing time, all gates/actors, snapshot reference, baseline/request/diff,
secret version metadata, SSM status, approved/deployed commit, service/task convergence, data acceptance and app-owner
E2E reference. Record application attestations separately from independently verified evidence.

Use real CloudTrail/RDS events for sandbox/live AWS where authorized; `cloudtrail:LookupEvents` is needed.
Only the local emulator skips unsupported CloudTrail collection. Do not run the EKS-specific evidence collector
unchanged for BB3. Finalize hashes **after** command logs, timeline, reports and uploads stop changing; preserve the
initial collection manifest and add a separate final manifest if it is stale. Verify local hashes and uploaded copies.
The local restore's initial manifest had stale entries after runner completion and is not final integrity proof.

Post Investigating at T1, Update after restore/cutover, Services Restored after app-owner GO, and a closure report
with actual RTO/RPO and target misses. Use the existing [communications templates](../../templates/communications/05-planned-drill-notices.md)
and [drill report](../../templates/reports/drill-report.md).

## 7. Sandbox Entry Gate

Use only the approved sandbox profile/account and Terraform-managed lab. Plan to a file, review, then apply that file.
Do not reuse a real BB3 SSH hostname, secret, deployment repository target or AWS profile for sandbox tests.
Before certifying this runbook, test a sandbox Swarm target and mock mixed secret, SSM least privilege/no value leakage,
manual and dev/uat SSH deployment paths, failed deployment/NO gates, app-owner verification and reconciled failback.
Production remains manual. Current sandbox EKS fixtures alone do not exercise this Swarm application path.

## Change Log

| Version | Date | Change | Trigger |
|---|---|---|---|
| 0.1-draft | 2026-10-19 | Separate BB3 snapshot/Swarm procedure adapted from the local SQL-free S3 drill; manual/SSM secret and manual/SSH deployment choices | Owner priority: sandbox and BB3 Docker Swarm |