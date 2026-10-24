# RB-BB3-S3 - UAT Snapshot Recovery, Swarm Failback And Retirement

| Field | Value |
|---|---|
| Runbook ID / version | RB-BB3-S3 / v1.0 |
| Service | BB3 RDS PostgreSQL primary/read replica and Docker Swarm application consumers |
| Execution scope | Approved sandbox account, `ENV=uat`, region `ap-southeast-1`; not real BB3 UAT or production |
| Owner / review / approval | `{{SRE_OWNER}}` / SRE, application owner and data owner / `{{APPROVER}}` |
| Recovery | Snapshot -> new primary and replica -> endpoint-only Secrets Manager update -> external app deployment |
| Targets | RPO 24 hours; Service RTO 30 minutes (`T8-T0`); business validation measured separately |
| Status | Consolidated UAT-sandbox operational reference; named owner review and real-UAT adoption approval remain required |
| Application evidence | Owner-attested deployment, health and transaction evidence; not independently verified by the helpers |

## 1. Quick Manual

Run from the repository root on the operator's Mac after reviewing section 2. Run each phase
separately and review every approval prompt. External application deployment remains manual.

### 1.0 Install Workstation Tools (macOS)

On a fresh Mac, first install [Homebrew](https://brew.sh/) using its official instructions, including
the displayed shell setup command. Its setup may require Xcode Command Line Tools and administrator
approval; enter any password directly in the local terminal, never in chat. Once `brew` is available,
install the BB3 recovery/failback/retirement tools together:

```bash
brew install bash coreutils python awscli jq git
eval "$(brew shellenv)"
```

`python` provides `python3`; `coreutils` supplies GNU utilities used by repository scripts. The shell
setup makes Homebrew tools available in the current terminal; retain Homebrew's recommended shell
profile setup for future terminals. Existing up-to-date packages are retained by `brew install`.
Run subsequent DR commands from the cloned repository root. No `pip install`, virtual environment,
database client, Docker or Kubernetes installation is required for these BB3 script paths.

For local mocked tests and lint only, also install:

```bash
brew install shellcheck expect
```

Building/changing the lab infrastructure additionally requires Terraform; follow
[the Terraform setup guide](../../iac/README.md). These tool-install commands do not configure AWS
profiles, grant permissions, create the ignored sandbox config or start a DR run. Each operator still
needs approved account access and reviewed configuration; do not copy another operator's credentials.
This installation recipe is macOS-specific, not a Windows/Linux bootstrap.

Isolated check (2026-10-23): prerequisites installed in a clean Ubuntu 24.04 ARM64 container using
AWS's official CLI v2 installer. Runner listing, 62 Python tests and mocked recovery/failback/prompt
checks passed without host mounts, credentials or a real sandbox config. This checks script dependencies,
not fresh-Mac Homebrew installation, AWS access or a live DR exercise.

### 1.1 Whole DR Run

```bash
bash iac/lab/bb3-db/bb3-run.sh S3
```

On the first run, executes P0-S01 through P5: discovery, baseline, controlled traffic cutoff,
restore/hardening, new replica, endpoint cutover, app validation, T10 approval and local packaging.
Save the printed run ID. On rerun it checks the saved run and offers a suggested continuation:
press Enter to continue, or `n` to cancel without running a step. Existing mutation/app-owner approvals
still require explicit input. Completed workflows are reported without repeating them.

Use `S3 --new` only for a deliberately separate drill after reviewing the previous run; it starts
discovery and fault injection rather than continuing. It cannot combine with ranges or failback.

### 1.2 Failback

Replace the placeholder with the exact completed recovery run ID, never `latest`:

```bash
DR_ID='{{COMPLETED_CUTOVER_DR_ID}}'
bash iac/lab/bb3-db/bb3-run.sh S3 --failback "$DR_ID"
```

No extra `--apply` is needed: preview precedes restored-pair fencing and guarded endpoint return.
After interruption, rerun this same command. It checks matching saved journals and offers the next
incomplete action; Enter accepts the continuation, not the mutation approvals. P3-S01 fence and
P3-S01 original release are tracked separately. An incomplete fence is resumed, never skipped.
The command then releases originals and collects deployment, health, transaction and sign-off evidence.
Typed approvals remain mandatory. The app owner drains consumers and performs external deployment.
Data-owner reconciliation or an identified sandbox data-loss decision must precede failback; endpoint
return does not copy writes to the original DBs.

### 1.3 Remove Restored Resources

Only after completed failback sign-off and explicit retirement/data-retention approval:

Set `DR_ID` in the current terminal to the exact recovery run ID whose failback was signed off.
Replace the placeholder below before running either command. Use the ID printed during recovery
or recorded in its saved evidence, never `latest`. A new terminal does not retain the variable
from section 1.2; do not assume it is already set.

```bash
DR_ID='{{COMPLETED_CUTOVER_DR_ID}}'
printf 'Selected retirement run: %s\n' "$DR_ID"
bash iac/lab/bb3-db/retire-restored.sh --failback "$DR_ID"
```

Verify the displayed ID before approving deletion. Alternatively, pass that exact run ID directly
after `--failback` instead of using `$DR_ID`.

Review scope and type `RETIRE-RESTORED-PAIR` only when approved. This permanently deletes the restored
replica/primary, run-owned quarantine SG, restored automated backups and temporary retirement snapshot.
Original DBs/backups, the source restore snapshot, unrelated resources and evidence remain. Enter cancels.
There is no minimum waiting period or automatic scheduling. This does not destroy the entire sandbox.

## 2. Scope, Roles And Prerequisites

S3 means **snapshot restore**, not S3 object storage. BB3 S4/PITR remains unsupported by this runner.
This procedure is for the UAT-role sandbox, not real UAT, DEV/EKS or Moto/LocalStack. Do not use EKS
`dr-run.sh`, ESO, Reloader or Kubernetes rollout commands for the Swarm application path.

The sandbox is managed by [the BB3 lab stack](../../iac/lab/bb3-db/README.md). Use
[the Terraform wrapper](../../iac/README.md) for infrastructure changes: save a plan, review it, obtain
approval, then apply that file. Standalone retirement is the narrow owner-approved AWS CLI exception;
it does not authorize ad-hoc cleanup of other resources.

| Role | Responsibility |
|---|---|
| Incident commander | Scope, change window, communications, restore/cutover approval and T10 |
| DR operator | Pinned-account API checks, baseline, restore/hardening, journals and guarded endpoint coordination |
| Data owner / DBA | Snapshot loss acceptance; restored-side write reconciliation or explicit identified sandbox data-loss decision |
| App/platform owner | Inventory/drain, secret custody, external deployment, session closure, app health/business tests and failback sign-off |

These roles may be held by different people. The app owner does not have to match the DR operator,
data owner or IC/T10 approver. Deployment, health and transaction attestations must use the same
app-owner name; failback deployment/sign-off must match its confirmed app-owner fence record.
Packaging reuses the T10 approver as evidence owner, not as a replacement app owner.
Name entry is once per role/run: SRE/IC approver name and role at T10, and app-owner name at the
first fence confirmation. Later deployment, health, transaction, failback fence/sign-off and retirement
display/reuse the matching saved app owner instead of asking again. Legacy runs lacking that record
still require the first app-owner entry. Names are attestations, not authenticated identity proof.
Failback sign-off has one final `SIGN-OFF-FAILBACK` approval after the evidence summary; there is no
extra readiness yes/no or owner-name question. Enter leaves sign-off pending. Deletion remains a
separate typed approval, and existing signed-off records are not overwritten.

### 2.1 Operational Prerequisites

- Use Bash, Python 3, AWS CLI v2 and jq from the repository root. Python helpers use the standard library.
- Review ignored `iac/sandbox.env`: sandbox profile/account, `ENV=uat`, region, source pair, snapshot and
  unused restore targets. Never use `env/uat.env`, default credentials or a real-account profile for this lab.
  SSO `lab_sandbox` is preferred; approved sandbox-only key profiles require owner authorization.
- Unset exported AWS access keys/session tokens. Every AWS call pins its named profile and region;
  account guards must pass. SSO login, when required, happens in the local terminal/browser.
- Have approved STS, RDS, EC2 SG, Secrets Manager metadata/endpoint-update and KMS permissions. Retirement
  also needs snapshot and exact-resource automated-backup describe/delete permissions.
- Endpoint helpers handle mixed JSON in memory through authorized sandbox custodian access, including
  `GetSecretValue`/`PutSecretValue`. This is not a metadata-only IAM role. Never display or save credential
  payloads; keep CLI history disabled, tracing off, and evidence restrictive and Git-ignored.
- Record the IC, app/data owners, window, consumer inventory, snapshot acceptance, reconciliation plan and
  traceable evidence locations. Do not invent references or sign prompt-test inputs as actual app proof.
- The external `bb3-infrastructure` repository is not in this workspace. The app owner verifies the host,
  clean approved `main` commit, deployment procedure and all consumers. Keep real host/account identifiers
  in ignored config. Do not automate passwords, privileged interactive login or insecure SSH host-key bypasses.

No SQL, password repair or operator probe writes are part of this workflow. Preserve credentials and unrelated
secret fields during endpoint changes. Mutation prompts default to No; Enter is not approval. Never stop a
replica or a primary with replicas to implement fencing.

**Real UAT adoption gate:** helpers/configuration are sandbox-specific. Actual BB3 UAT needs separate
account/IAM/network, deploy-script, data-loss and execution-procedure approval and validation. Do not bypass
sandbox guards or substitute real credentials. This document is not production authorization or independent
Swarm/business-data certification. The legacy SSM updater uses `host`/`port`, not BB3's endpoint key pair;
it is not a drop-in alternative without reviewed schema/IAM changes and tests.

## 3. Runner Controls And Step Reference

Every step shows What/Expected descriptions; `--verbose` remains accepted.

Do not edit or update runner/helper files during an active drill. Bash can read later parts of a
script after a long wait; an in-place edit can cause a late syntax error even after packaging.
If T10/package output was already printed, verify the saved records and package before deciding
whether anything needs resuming. Plain `S3` checks saved completion; do not use `--new` to repair
a post-package shell error.

```bash
bash iac/lab/bb3-db/bb3-run.sh S3 --list
bash iac/lab/bb3-db/bb3-run.sh S3 --to P2-S09
bash iac/lab/bb3-db/bb3-run.sh S3 --from P3-S01 --to P5
bash iac/lab/bb3-db/bb3-run.sh S3 --only P0-S02 --show
bash iac/lab/bb3-db/bb3-run.sh S3 --from P2-S06 --to P2-S09 --list
bash iac/lab/bb3-db/bb3-run.sh S3 --failback "$DR_ID" --list
```

- Plain `S3` checks saved progress before starting/continuing P0-S01 through P5. `--to P2-S09` explicitly stops at RDS-only readiness.
- `S3 --new` deliberately resets only the runner checkpoint for a separate drill; it does not delete evidence or bypass existing resource/fence guards.
- Main-command continuation uses the explicit saved config run ID, never an automatic `latest` failback selection.
- Checkpoints cover every recovery/action boundary. Legacy journals are checked conservatively; uncertain hardening is revalidated, not claimed complete.
- Interrupted restore/create checks existing target tags/topology read-only and selects the waiter if the request was accepted; foreign/ambiguous targets block continuation.
- Modified config/identity, malformed evidence or failed hashes block continuation. Existing app evidence and typed approvals are never fabricated.
- `--list` stays action-free; explicit `--only` and ranges keep their manual behavior. Non-interactive continuation stops rather than assuming Enter.
- `--from`/`--to` are inclusive; `--from` alone ends at P4-S02. Select P5 explicitly for closeout.
- `--only` runs comma-separated IDs in supplied order. Step-specific arguments require one ID and are
  forwarded after `--only STEP`. Do not combine `--only` with ranges.
- Top-level `--failback DR-ID` selects guided failback only and cannot combine with ranges/`--only`.
  Single-step failback with `--failback` after `--only STEP` remains available.
- `--list` is action-free. Invalid selections fail before actions. P3-G0 and FB labels are manual gates;
  P4-G4 and P5 are executable closeout steps.

| Step | Action | Completion evidence |
|---|---|---|
| P0-S01 | Discover source pair, snapshot and unused targets | Reviewed saved selections |
| P0-S02 | Capture pre-quarantine API baseline | Checksums, original SG sets, configuration and parameter records |
| P0-S03 | Simulate app failure by cutting off new DB traffic with a no-ingress SG | Both source attachments active; actual app/monitor failure reference |
| P1-S01-1 | Record evidence-based T0 | UTC impact time/reference for the same run ID |
| P1-S01-2 | Declare T1 for S3 without reselection | T1 >= T0; reference if T1 edited/backfilled |
| P2-S00 | Preview metadata, tags, parameters and requests | Read-only comparison reviewed |
| P2-S01 | Restore new primary | Approved loss window/IC GO/mutation; unique target submitted |
| P2-S02 | Wait for primary | RDS available |
| P2-S03 | Harden/validate primary | Captured primary settings and parameters checked |
| P2-S04 | Wait after primary hardening | RDS available |
| P2-S05 | Create separate restored replica | Approved creation; original replica unchanged |
| P2-S06 | Wait for new replica | RDS available |
| P2-S07 | Harden/validate replica | Captured replica settings and restored source association |
| P2-S08 | Wait after replica hardening | RDS available |
| P2-S09 | Inspect both targets | Read-only status/configuration/topology |
| P3-G0 (manual) | Approve cutover | Explicit gates at P3-S01/P3-S02 |
| P3-S01 | Verify original P0 quarantine and session closure | Matching fence record; no second recovery SG change |
| P3-S02 | Update or verify both secret endpoints | Matching fence; correct target pair/version metadata |
| P3-S03 | Deploy automatically/guided over local SSH, or confirm manual deployment | App owner and sanitized deployment log |
| P4-S01 | Attest app-level DB health | UTC T8 and health evidence |
| P4-S02 | Attest business transaction/readback | UTC T9 and non-secret reference |
| P4-G4 | Declare service restored | Approver/role, explicit T10 and immutable closeout |
| P5 | Automatically package validated journals | Frozen local snapshot/hashes/archive/receipt; no input/upload |

## 4. Recovery Procedure

### 4.1 P0/P1: Baseline And Impact

Discovery matches `env=uat` and `app=bb3`. Review source/attached replica, snapshot age/source/encryption
and unused targets. Saved/sole choices and newest automated snapshots may be Enter defaults; fallback
without matching tags has no primary default. Saving selections updates ignored config, not AWS.

Capture complete API metadata before impact: both DB descriptions, tags, SG/subnet metadata and paginated
parameter records. Retain checksums and original SG sets. **Do not recapture a quarantined source**:
restore requests must use the original SG sets, not live quarantine attachments.

P0-S03 allocates the run ID and submits both source SG changes before waiting. Keep app/monitor active;
P0 does not require pausing writers/jobs. Verify no-ingress attachments and actual failed-new-connection
evidence. Existing sessions may survive an SG change; closure is a separate P3 confirmation.

T0 reflects evidenced impact, not merely command time. Accept displayed UTC only when the evidence
supports it; otherwise enter the actual UTC impact time. T1 defaults to declaration time, must be >= T0,
and needs evidence when edited/backfilled. S3 is recorded without a second scenario prompt. Preserve the
same P0 run ID throughout. Use UTC ISO-8601 timestamps.

### 4.2 P2: Restore, Harden And Wait

Preview checks baseline integrity and captured-versus-snapshot/current metadata. For differing non-reserved
tags, choose captured-primary or snapshot values; choices affect new targets only. Non-tag drift requires
`ACCEPT-DIFF`; parameter drift requires `USE-CURRENT-PARAMETERS` or cancel. Historical parameter-group
values cannot be reconstructed automatically. Stop when historical values are required but unavailable.

Review the fresh target, snapshot/loss window, class/AZ, private exposure, subnets/SGs, parameter group,
storage/encryption, retention/windows and tags before approving billable restore. Use baseline-driven
[request builders](../../automation/scripts/rds-requests.jq), never guessed CLI defaults. Maintenance windows
are applied during post-create hardening, not snapshot restore. Older CLI models may defer unsupported
backup inputs to hardening; final parity checks still apply.

Compare every required setting and parameter record, not only the group name. The prior sandbox capture
had writer retention 7 days, replica retention 0 days and 437 parameters per DB; use the reviewed current
baseline, not universal assumptions. See [configuration parity](../common/CP-03-restored-instance-config-parity.md).

A snapshot restore does not repoint the original replica. Create a separate replica of the restored
primary, then validate captured replica settings, or the primary template if no replica existed. Never
delete/promote/stop original replicas to simplify this workflow. PostgreSQL promotion and Oracle
`switchover-read-replica` are different scenarios, not snapshot-restore failback.

Wait steps are separate: single-step restore/create needs its P2-S02/P2-S06 waiter afterward. For manual
selections only, post-hardening waiters may be omitted when no changes occurred and available is verified.
Default/ranged recovery includes them. Record primary-ready and full-topology-ready times separately.
RDS waiters display elapsed `HH:MM:SS`, updated once per second on the same terminal line. This also
covers fencing and retirement RDS waits; it is not a percentage or finish-time estimate. Redirected
output records only the start and final timer lines. Ctrl+C stops the waiter; review the printed
same-run resume command rather than resubmitting a restore/create request.
Available/configuration parity is infrastructure evidence, not app connectivity or business proof.

### 4.3 P3: Fence, Endpoints And Deployment

Inventory and drain all writers/readers/workers/jobs under app-owner control for cutover. P3-S01 verifies
the same run's P0 quarantine and requires existing-session closure. It neither repeats recovery SG changes
nor stops a primary with replicas. No endpoint switching before verified isolation and session closure.

P3-S02 offers automatic CLI update or verification of a custodian's manual update. Review both hosts and
the selected run/secret. Only `DB_HOST`/`DB_REPLICA_HOST` may change; preserve credentials/unrelated JSON
and record previous/new version IDs. No mixed payload is printed. Both modes require the matching fence
and explicit confirmation: `UPDATE-ENDPOINTS` for automatic write, `ENDPOINTS-ALREADY-UPDATED` for manual
verification. Default/ranged execution supplies `--apply`, not approval; single-step remains preview-only:

```bash
bash iac/lab/bb3-db/bb3-run.sh S3 --only P3-S01
bash iac/lab/bb3-db/bb3-run.sh S3 --only P3-S02 --apply
bash iac/lab/bb3-db/bb3-run.sh S3 --only P3-S03
```

Changing Secrets Manager alone does not reload tasks or immutable Docker secrets. In automatic/guided
mode the helper runs the remote deploy script, waits for tasks and replica counts, then displays services,
tasks and recent logs. The app owner still reviews the real output and verifies every consumer loads the
new secret and the expected version/commit. In manual mode the app owner performs the approved external
deploy/restart first, then records the sanitized evidence. Some Running tasks or green infrastructure
checks alone are insufficient. Do not collect rendered credentials or raw sensitive logs.

P3-S03 option 1 runs the guarded automatic sequence from the operator's local terminal using one SSH
call per remote command. It maps dev to `dev-1.app.beepte.ch` and uat to `uat-1.app.beepte.ch`, requires
a clean `main` worktree preflight and typed `DEPLOY-DEV`/`DEPLOY-UAT` approval, then runs `git pull --ff-only`,
`scripts/deploy.sh <env>`, waits for Running tasks and matching service replicas, and displays services,
tasks and recent logs. Normal SSH host-key checks remain enabled. It does not use sudo. Real automatic
production deployment is refused by this UAT-role workflow; the Docker mock can display `live-1.app.beepte.ch`
and the production-only `sudo su` instruction, but never executes them.

`BB3_DEPLOYMENT_HOST` sets the SSH DNS destination and must match the allowlisted host for `ENV`
(`dev-1.app.beepte.ch` or `uat-1.app.beepte.ch`). `BB3_DOCKER_STACK_NAME` sets the verified Swarm
stack (`beepbeep` by default). A value inconsistent with `ENV` is refused before remote commands.

`BB3_DOCKER_LOCAL_CONTEXT` selects the Docker SSH mock. When set, P3-S03 uses that local Docker context
and never falls back to real SSH if Docker fails. When blank or unset, P3-S03 uses real local SSH with
typed approval to `BB3_DEPLOYMENT_HOST`. The committed sandbox example leaves this variable blank for
real SSH; set it to `colima-dr-framework` to select the local mock. Mock output shows simulated passes
but exits without deployment evidence, so P3-S03 remains pending.
To explicitly use real SSH for one P3-S03 invocation while keeping the Docker mock configured, append
`--real-ssh`:

```bash
bash iac/lab/bb3-db/bb3-run.sh S3 --only P3-S03 --real-ssh
```

Failback step form: `bash iac/lab/bb3-db/bb3-run.sh S3 --only P3-S03 --failback "$DR_ID" --real-ssh`.
Real SSH still requires the typed `DEPLOY-ENV` gate and allowlisted host matching `ENV`; production is refused.

Option 2 runs the same steps one at a time: Enter runs, `n` stops all later commands, and `s` skips.
Skipping `git pull`, deploy or convergence blocks a completed deployment result. Optional service/task/log
checks may be skipped. Both SSH modes require the local SSH identity/agent and host already authorized by
the operator; the script does not copy keys, disable host checking or save raw remote output.

The Docker test image runs this same orchestrator using the real OpenSSH client/server protocol to an
isolated loopback mock host, `--network none`, a read-only root filesystem and no host mounts. A
synthetic clean-main Git repo and fake Docker command provide remote results; it contacts no EC2 host,
external repo or Docker daemon from inside the container. It creates the temporary container named by
`BB3_DEPLOYMENT_CONTAINER` (default `bb3-deploument-ec2`) and removes only that test container afterward.
This name is not an EC2 instance or a real deployment target. The test validates command order/results
only, not real deployment or app behavior. To run it where Docker is available:

```bash
DOCKER_CONTEXT=colima-dr-framework bash iac/lab/bb3-db/test-bb3-deployment-docker.sh
```

The test highlights build phases and each Dockerfile layer, showing only the last few layer lines
to keep the terminal readable. Full image-build and SSH-session logs are retained in ignored
`evidence/bb3-deployment-mock/<timestamp>-<pid>/`; `NO_COLOR` disables terminal color.

Option 3 means the app owner already completed the approved manual deployment. It prints the
[BB3 Deployment Guide](https://beep-technologies.atlassian.net/wiki/spaces/BB3/pages/1216610316/BB3+Deployment+Guide#Deploying)
and then records the selected app owner, sanitized multiline convergence log and explicit endpoint/
convergence confirmation. A retained nonempty regular log can be reused when no attestation exists;
saved attestations are not overwritten. Automatic and guided command output is shown live but not claimed
as independent evidence; the owner still reviews deployment and confirms both endpoints/tasks before P3-S03.

### 4.4 P4/P5: App Validation, T10 And Packaging

P4-S01 records T8 after app-owner confirmation of an app-level DB health check with evidence. RDS
available, direct operator login and deployment convergence alone are not T8. P4-S02 requires a successful
business transaction/readback through the intended DB paths and a non-secret reference before T9. Do not
use operator probe writes or fabricate successful attestations. Resume jobs only with app-owner approval.

Report Service RTO as `T8-T0`, business validation as `T9-T8`, and total through business validation as
`T9-T0`. RPO is separate and not independently measured by packaging. Retain target misses and operator
pauses; do not adjust them away or equate local/mock timings with AWS performance.

P4-G4 validates matching incident, cutover, fence, deployment, T8/T9 journals and shows timeline/references.
Supply approver name/role and actual T10 UTC (Enter accepts current UTC). No ticket reference is requested.
Restrictions default to `none`. Type `DECLARE-RESTORED` to approve reviewed references, or `EDIT` to correct
them before the same final approval. Immutable `closeout.json` does not overwrite recovery milestones.

P5 is prompt-free: reuse closeout approver and ignored `evidence/bb3-packages`, validate hashes and create
an allowlisted frozen snapshot, summary, SHA-256 manifest/archive/checksum and receipt. Deployment logs,
configs/secrets, raw baseline directories and external reference targets are omitted, not automatically
reviewed. No upload or external-evidence verification is claimed. Legacy ticket-bearing closeouts remain
compatible; immutable records/packages are not overwritten. Packaging failure is not permission to delete
old evidence or backdate another T10.

## 5. Failback Procedure

Obtain a separate window, app-owner approval and data-owner decision covering restored-side writes.
Reconcile or explicitly approve the identified sandbox loss interval and evidence; originals are not
automatically current/safe. `ACCEPT_LOCAL_DATA_LOSS` belongs to local fixtures, not BB3 business approval.

| Phase | Executed action | Gate / result |
|---|---|---|
| FB-01 | P3-S02 `--failback DR-ID --preview` | Read-only restored CURRENT vs original RETURN-TO endpoints; saved secret/run reused |
| FB-02 | P3-S01 `--failback DR-ID` | App drain; approved restored-pair quarantine and separate session closure |
| FB-03 | P3-S02 `--failback DR-ID --apply` | Matching restored fence; typed `FAILBACK-ENDPOINTS`; preserve credentials/unrelated keys |
| FB-04 | P3-S01 `--failback DR-ID --release-quarantine` | Fresh restored isolation; typed `RELEASE-SOURCE-QUARANTINE`; saved original SGs restored and original quarantine removed |
| FB-05 | P3-S03, P4-S01, P4-S02 with `--failback DR-ID` | External deployment to originals, health and successful transaction/readback |
| FB-06 | Sign-off offer within P4-S02 | Review saved references; matching owner and typed `SIGN-OFF-FAILBACK` |
| FB-07 | Standalone retirement | Separate scoped preview/deletion approval; section 6 |

Guided failback runs FB-01 through the FB-06 offer in order. First P3-S02 is preview-only; the later one
applies after fencing. What/Expected descriptions distinguish repeated step IDs/actions. No P0/P2 recovery
is repeated. Declining sign-off leaves approval pending even if prior script steps completed successfully.

Restored quarantine uses a separate run-owned no-ingress SG, saves prior attachments and verifies both
active attachments. Session closure remains separately confirmed. Original release freshly checks restored
isolation and exact saved original SG IDs/active status; RDS available alone is insufficient. Up to 24
checks/five-second intervals show progress; timeout retains the source quarantine and unreleased journal.
Retry verifies already-restored sets without resubmitting modification. Never un-fence both pairs.

### 5.1 Continue After An Interrupted Release

Do not restart guided failback blindly after an uncertain mutation. Inspect journals/live state and retry
the affected action. The main command checks saved progress and proposes that action without manual
step selection:

```bash
bash iac/lab/bb3-db/bb3-run.sh S3 --failback "$DR_ID"
```

Review the displayed run/action and press Enter to continue. For a deliberately selected original-release-only retry:

```bash
bash iac/lab/bb3-db/bb3-run.sh S3 --only P3-S01 --failback "$DR_ID" --release-quarantine
```

After release succeeds, complete the app-owner steps one at a time with actual evidence:

```bash
bash iac/lab/bb3-db/bb3-run.sh S3 --only P3-S03 --failback "$DR_ID"
bash iac/lab/bb3-db/bb3-run.sh S3 --only P4-S01 --failback "$DR_ID"
bash iac/lab/bb3-db/bb3-run.sh S3 --only P4-S02 --failback "$DR_ID"
```

Release alone is not completed failback. Retirement blocks missing/mismatched deployment, health,
transaction or sign-off records. Separate `failback-app-deploy.*`, `failback-app-health.json` and
`failback-app-e2e.json` refer to originals; recovery T8/T9 and the frozen P5 package stay unchanged.

P4-S02 reuses saved transaction/time on retry and displays saved deployment, health and transaction
references without three extra reference prompts. Review actual evidence, confirm matching owner and
type `SIGN-OFF-FAILBACK` for immutable `failback-signoff.json`, UTC approval time and local hashes. This
also creates immutable, hash-linked `failback-report.md`/`.json` with result, evidence status and retirement
state. Existing supplemental references stay preserved; placeholders are not converted into proof.
External evidence is owner-attested. Sign-off does not approve disposal; the optional retirement offer defaults to No.

## 6. Scoped Retirement And Repeat Drills

Use section 1.3 only after failback sign-off and retention/disposal approval. Retirement checks sign-off
hashes, original endpoint values, restored IDs/run tags/topology, deletion protection and quarantine.
It requires scope review, matching owner, a retirement/data-retention reference and `RETIRE-RESTORED-PAIR`.
Never fabricate journals, detach retained DBs from quarantine or disable protection to bypass refusal.

The script verifies a temporary primary safety snapshot, deletes replica before primary and waits for
absence. It deletes the run-owned quarantine SG only after DB/ENI detachment. Under the same approval it
purges automated backups for the exact restored DB resource IDs and the verified retirement-created
snapshot. Original DBs/backups, source restore snapshot, other snapshots/SGs, shared networking, secrets
and evidence remain outside scope. Removal of restored recovery data is irreversible.

Timestamped stages 1-7 show waiter start/completion and resume guidance, not invented percentages.
Ignored `retirement.json` pins identities and requested operations. Timeout, pending ENIs, changed metadata
or incomplete backup deletion is **not completion**. Inspect state, then resume the same explicit command.
Completed deletions are not blindly repeated; snapshots marked for purge are not recreated. Older
retained-backup journals require fresh scope review/typed approval. Completed retry verifies absence read-only.

Successful completion prints a highlighted `RETIREMENT COMPLETE` banner with the run ID and separate
`REMOVED - absence verified` and `RETAINED - outside deletion scope` lists. Terminal highlighting
respects `NO_COLOR`; redirected output stays plain. A completed retry explicitly says it was a
read-only verification and made no changes. It also writes a versioned `retirement-report-<audit-time>.md`
and SHA-256 sidecar under the run evidence directory; the terminal banner points to that report. The retained
list is scope information, not a new backup audit.

If a restored-resource check blocks retirement, the message identifies the DB, each failed check,
expected/observed values and a safe next action. For an approved RDS/SG change still in progress,
wait for completion and recheck. Identity, topology, VPC or quarantine drift requires owner investigation;
do not edit pinned journal IDs, disable deletion protection or detach quarantine to bypass refusal.
The message prints the same-run retry command for use only after review. Earlier completed deletions
and their journal remain; no later action or automatic repair is performed after the refusal.

Retirement already includes restored-quarantine deletion. No separate `--cleanup-failback-quarantine` is
needed afterward. That older helper deletes only a verified detached SG after separately approved DB
retirement; it never deletes retained DBs/snapshots/backups.

After verified retirement completion and app-owner confirmation of the original serving pair, a new
`S3` drill may start. Review discovery against originals, a valid snapshot and unused targets; save the
new run ID for its failback/retirement. Never reuse the old incident as a new drill.

## 7. Evidence, Reporting And Approval Limits

Retain ignored `evidence/bb3-secret-endpoints/<DR-ID>/` journals, baseline checksums, ready times, endpoint
version metadata, deployment/health/business references, T0/T1/T8/T9/T10, approvals, failures, reconciliation,
restrictions and retirement progress. Preserve historical records/frozen hashes. Supplement failback and
disposal evidence separately, never by rewriting the recovery package.

Owner-entered references and approvals are not independent verification of deployment, transactions,
reconciliation or RPO. Mock/script tests verify selected control flow/safeguards, not real UAT/production
recovery or performance. Historical local/sandbox results are not certification. Preserve target misses
and corrective actions with owners/due dates.

Where authorized, collect real CloudTrail/RDS events as supplemental evidence; the EKS collector is not
a drop-in BB3 collector. Local packaging is not upload or audit coverage. Use the
[communications templates](../../templates/communications/05-planned-drill-notices.md) and
[drill report](../../templates/reports/drill-report.md) with actual measurements and limitations.

## 8. References And Change Log

- [Runner and sandbox setup](../../iac/lab/bb3-db/README.md)
- [Configuration parity](../common/CP-03-restored-instance-config-parity.md)
- [RPO/RTO definitions](../../docs/04-rpo-rto-measurement.md)
- [Evidence and audit](../../docs/05-evidence-and-audit.md)
- [Account safety](../../docs/12-account-and-cluster-safety.md)
- [AWS RDS stop limitations](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_StopInstance.html#USER_StopInstance.Limitations)
- [AWS read replica behavior](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_ReadRepl.html)

This is the maintained BB3 UAT-sandbox execution reference, consolidating the BB3 portion of the temporary
development notes. Their legacy DEV/EKS walkthrough is not part of this procedure. Consolidation is not a
new live drill, owner approval or certification of real BB3 UAT.

| Version | Date | Change | Approval status |
|---|---|---|---|
| 1.0 | 2026-10-23 | Current S3 runner, guarded endpoints, app attestations, prompt-free P5, guided failback, SG convergence and scoped script-only retirement | Pending named owner/reviewer approval; sandbox scope only |
| 0.1-draft | 2026-10-19 | Initial snapshot/Swarm adaptation from local SQL-free exercises | Superseded execution instructions; not real-UAT certification |