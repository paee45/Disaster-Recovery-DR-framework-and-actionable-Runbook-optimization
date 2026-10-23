## BB3 AWS Sandbox DR Runbook

> Maintained BB3 UAT-sandbox reference: [RB-BB3-S3](bb3/RB-BB3-S3-snapshot-restore-swarm.md).
> The BB3 procedure below was consolidated there as v1.0. Use that runbook for execution and future updates;
> keep these development notes as background only. Legacy DEV/EKS material below is not BB3 procedure.

### Quick Manual

Approved BB3 sandbox only. Run from the repository root after reviewing `iac/sandbox.env`
and the prerequisites below. Run each phase separately; review every approval prompt.

#### 1. Whole DR Run

```bash
bash iac/lab/bb3-db/bb3-run.sh S3
```

Runs discovery, failure simulation, snapshot restore, endpoint cutover, app validation, T10
approval and automatic local packaging. App deployment and business checks remain manual.
Save the printed DR run ID. Do not rerun this command to resume an interrupted recovery;
review the journals/current state and use the appropriate single-step continuation.

#### 2. Failback

Replace the placeholder with the exact completed recovery run ID, not `latest`:

```bash
DR_ID='{{COMPLETED_CUTOVER_DR_ID}}'
bash iac/lab/bb3-db/bb3-run.sh S3 --failback "$DR_ID"
```

No extra `--apply` flag is needed on this guided command: it previews first, then invokes the
endpoint apply step after fencing. Typed approvals are still required; starting the command alone
does not change endpoints or approve failback.

First approve data reconciliation or the identified sandbox data loss. The command guides
restored-pair fencing, endpoint return, original-pair release, app deployment confirmation,
health, transaction and sign-off. Drain/redeploy the app through its approved external procedure.
Endpoint failback does not copy writes back to the original DBs.

#### 3. Remove Restored Resources

Only after completed failback sign-off and explicit retirement/data-retention approval:

```bash
bash iac/lab/bb3-db/retire-restored.sh --failback "$DR_ID"
```

Review the scope, then type `RETIRE-RESTORED-PAIR` only when approved. This permanently deletes
the restored replica/primary, their run-owned quarantine SG, their automated backups and the
temporary retirement snapshot. Original DBs/backups, the source restore snapshot and evidence
are retained. Enter cancels. This does not destroy the entire sandbox.

### Scope, Safety And Prerequisites

This procedure is for the approved BB3 PostgreSQL sandbox, not real UAT, Moto/LocalStack, or DEV/EKS.
**S3** means restoring a new primary from an RDS snapshot, not an S3 object. BB3 **S4/PITR remains backlog**;
do not substitute the EKS `dr-run.sh`. The source may be primary-only or a primary/replica pair. Snapshot
restore does not repoint the old replica; the recovered primary needs its own new replica.

- Run from the repository root with Bash, Python 3, AWS CLI v2, jq, and an interactive terminal.
  Python helpers use the standard library.
- Review the approved named sandbox profile/account, region, environment and DB selections in ignored
  `iac/sandbox.env` (`ENV=uat` and all four DB IDs for the paired drill). Do not use `env/uat.env`, default
  credentials, or exported AWS keys. SSO is preferred. Verify the selected identity is the approved sandbox
  before mutations; runner/helper account guards must pass.
- Have permissions for STS identity, RDS discovery/snapshots/restore/replica creation/settings/SG operations,
  Secrets Manager metadata and endpoint updates, and KMS where required. Endpoint helpers need
  `ListSecrets`, `DescribeSecret`, `GetSecretValue`, `PutSecretValue`, and `UpdateSecretVersionStage`.
- Keep AWS CLI history disabled. Never fetch or print the mixed secret payload, passwords, or business
  payloads. The endpoint helper keeps JSON in memory and sends SecretString through stdin, not process
  arguments or payload files. Record only endpoint/version metadata in restrictive, ignored
  `evidence/bb3-secret-endpoints/<DR-ID>/` records.
- Do not edit the external application repository. External deployment must follow the separately approved
  application procedure. Automatic app deployment is unavailable; helper confirmation is an owner attestation.
- All mutation confirmations default to **No**. Review each request; Enter is not approval. Obtain data-owner
  acceptance of the snapshot loss window and typed IC `GO` before restore. Cutover needs separate owner/IC
  approval. Do not stop, delete, or promote DBs ad hoc. Never stop a replica or a primary with replicas.

RDS-only validation proves API/configuration/topology, not application recovery. Keep the legacy material
below its own heading separate from this workflow; its step IDs and controls belong to another runner.

### Runner Controls

Every executed step prints its **What** and **Expected** description by default. `--verbose` remains
accepted for compatibility; it is no longer required for descriptions. Approval gates remain active.
The following examples are alternatives, not a sequence to paste and run:

```bash
bash iac/lab/bb3-db/bb3-run.sh S3 --list
bash iac/lab/bb3-db/bb3-run.sh S3
bash iac/lab/bb3-db/bb3-run.sh S3 --to P2-S09
bash iac/lab/bb3-db/bb3-run.sh S3 --only P0-S01,P0-S02
bash iac/lab/bb3-db/bb3-run.sh S3 --only P0-S02 --show
bash iac/lab/bb3-db/bb3-run.sh S3 --from P2-S06 --to P2-S09 --list
bash iac/lab/bb3-db/bb3-run.sh S3 --from P2-S06 --to P2-S09
bash iac/lab/bb3-db/bb3-run.sh S3 --from P4-S01 --list
bash iac/lab/bb3-db/bb3-run.sh S3 --to P0-S02 --list
```

- No selection options: execute **P0-S01 through P5** as one guided recovery process, including
  discovery, fault injection, restore/wait/hardening, guarded endpoint cutover, manual application
  deployment/validation, service-restored approval T10 and prompt-free local packaging. Every approval
  gate remains active; external app deployment is not automated. Failback and retirement are separate.
  Use `S3 --to P2-S09` for RDS-only recovery. To continue after P2-S09, use
  `S3 --from P3-S01 --to P5`. Do not restart plain `S3` merely to continue an existing run.
- `--only` runs the listed comma-separated IDs in the supplied order. Step arguments such as `--show`,
  `--apply`, positional overrides, or failback options require exactly one `--only` ID. Omitted IDs use saved
  DB/snapshot/target selections; review any override. `--show` above redisplays the latest capture offline.
- Top-level `S3 --failback DR-ID` runs guided failback only, using the explicit completed recovery ID.
  Add `--list` for an action-free preview. It cannot combine with `--only`, `--from` or `--to`; existing
  single-step commands with `--failback` after `--only STEP` remain supported.
- `--from` / `--to` select an **inclusive** range. `--from` alone ends at **P4-S02**; `--to` alone starts at
  **P0-S01**. Ranges cannot combine with `--only`; they do not infer completed steps or skip waiters.
- `--list` alone shows executable steps without actions. For a selection-only preview, put `--list` with a
  range as shown; after `--only`, remaining options are forwarded as step arguments, not runner controls.
- Unknown IDs, reversed ranges, and invalid option combinations fail before steps start. **P3-G0 and
  FB labels are manual gates/checkpoints, not executable IDs.** P4-G4 and P5 are explicit closeout commands.
  `--from` alone still ends at P4-S02; select P5 explicitly to include closeout.
- Ctrl+C during a waiter prints its resume command. After an accepted mutation or uncertain command result,
  inspect P2-S09 first and resume the appropriate waiter, not a restore/create action or a new target.

### Authoritative Step Reference

Use this table for action order and completion evidence. The phase notes below cover decisions and limits,
not additional steps. `P` = phase, `S` = step, `G` = approval gate.

| Step | Action | Completion evidence |
|---|---|---|
| P0-S01 | Discover source pair, snapshot and restore targets | Reviewed selections saved |
| P0-S02 | Capture pre-quarantine API baseline | Checksums, original SG sets and configuration |
| P0-S03 | Simulate app failure by cutting off new DB traffic with a no-ingress SG on both sources | Both attachments active; real app/monitor failure reference |
| P1-S01-1 | Record evidence-based impact T0 | UTC time and evidence reference |
| P1-S01-2 | Declare incident T1 for the selected S3 scenario, without asking again | Same P0 run ID; T1 >= T0 |
| P2-S00 | Preview metadata, tags, parameters and requests | Read-only comparison reviewed |
| P2-S01 | Restore new primary | Explicit restore approval and submitted target |
| P2-S02 | Wait for primary creation | RDS `available` |
| P2-S03 | Harden/validate primary | Baseline settings and parameters checked |
| P2-S04 | Wait after primary hardening | RDS `available` |
| P2-S05 | Create new read replica | Explicit approval and submitted target |
| P2-S06 | Wait for replica creation | RDS `available` |
| P2-S07 | Harden/validate replica | Captured replica settings and topology checked |
| P2-S08 | Wait after replica hardening | RDS `available` |
| P2-S09 | Inspect both targets | Read-only status/topology |
| P3-G0 (manual) | Approve cutover | Approval collected in P3-S01/P3-S02 prompts |
| P3-S01 | Verify original pair quarantine and session closure | Matching verified fence record; no new source mutation |
| P3-S02 | Update or verify both secret endpoints | Endpoint pair verified against selected DBs |
| P3-S03 | Attest manual app deployment/convergence | App owner and sanitized multiline deployment log |
| P4-S01 | Attest running app DB health | UTC T8 and health evidence |
| P4-S02 | Attest business transaction/readback | UTC T9 and transaction reference |
| P4-G4 | Record service-restored approval | Immutable local closeout record with approver, UTC T10 and reviewed evidence |
| P5 | Automatically package validated local journals | Local snapshot, SHA-256 manifest/archive and receipt; no prompts, deployment logs or upload |

### P0/P1: Baseline And Evidence-Based Impact

Record incident ID, IC, data owner and app owner. Discovery verifies account/tags/topology without SQL or
secret-value reads. Select the primary and attached replica from numbered lists. Saved/sole selections and
the newest available daily automated snapshot are highlighted Enter defaults. If `env=uat` / `app=bb3`
matches are absent, discovery warns and offers PostgreSQL instances without a default. Review snapshot age,
status, encryption and potential lost writes. The final `[Y/n]` prompt saves reviewed selections and
deterministic targets in the existing ignored config; `n` cancels, unchanged values are not rewritten.

Capture complete API metadata under ignored `iac/lab/bb3-db/baselines/` before quarantine. Record its directory,
verify checksums and parameter groups `in-sync`, and retain it unchanged for the run. Primary-only capture is
refused if attached replicas were omitted. The **pre-fence SG baseline is pinned against recapture**; restore
uses those original SG sets, never the live quarantine SG.

P0-S03 allocates the run ID, checks live attachments against that baseline, and submits **both source SG
changes before waiting** so apply intervals overlap. Keep the app and monitor active: **no writer/job pause
in P0**. Wait for both no-ingress attachments and capture actual failed-new-connection evidence. An SG change
does not close existing sessions; session closure needs separate verification before cutover.

Use that evidence for T0, not merely the command time. Enter accepts the displayed current UTC only when
the actual evidence supports that time; otherwise enter the evidenced impact timestamp. Record T1 for the
same run ID; it defaults to declaration time, must be >= T0, and any edited/backfilled T1 needs a log reference.
The BB3 declaration records S3 automatically; it does not ask for S3/S4 again. S4/PITR remains unsupported.
Use UTC ISO-8601 (`YYYY-MM-DDTHH:MM:SSZ`).

### P2: Restore, Harden And Wait

Preview verifies baseline checksums and source/account/region, compares snapshot metadata/tags with the
captured primary, and compares captured primary parameter records with the live group. Snapshot APIs do not
return those parameter values. Review `MATCH`, `NEW` and `DIFF - REVIEW` fields before approval.

For each differing non-reserved tag, choose `1` for captured-primary or `2` for snapshot values. Choices apply
to new primary/replica tags, not the source or snapshot. `Name` uses the target ID, writer `Role` is `primary`,
and `dr-restore` records lifecycle. Non-tag metadata drift requires typed `ACCEPT-DIFF`. Parameter drift needs
explicit `USE-CURRENT-PARAMETERS` or cancellation. This selects current group values; it cannot recreate
historical group contents and does not waive later hardening checks. If historical values are required, stop.

Review the unused target, snapshot, chosen tags, parameter group, subnet/SGs, class/AZ, private access,
retention and backup window before accepting the billable restore. The request uses the baseline settings.
Maintenance window is **post-restore `ModifyDBInstance` hardening**, not a snapshot-restore API field; replica
maintenance is checked/applied after creation too. Same-Region replica creation inherits subnet/parameter
groups from the restored primary, so those fields are omitted from that create request.

Hardening compares the original baseline, restored configuration, supported modification fields and captured
parameter API records. An expected group name with differing values stops for review; the helper cannot
rebuild old group contents. Review any separately prompted group/setting change, then confirm `available`,
parameter group `in-sync`, parameters, SG/subnet topology, private exposure, class, retention and windows.
Replica creation requires the primary checks to pass. Replica checks use the captured source replica, or the
primary template when no source replica existed. For this captured drill, writer retention is **7 days** and
replica retention **0 days**; do not copy writer retention to the replica. The historical capture had **437 API
parameters per DB**, not a universal AWS parameter count.

**Waits are separate actions.** `--only P2-S01` and `--only P2-S05` do not automatically wait: use P2-S02
and P2-S06 respectively. Post-hardening P2-S04/P2-S08 may be omitted in a manually selected sequence only
when hardening made no changes and the corresponding DB is confirmed `available`. Ranges include them
without implicit skips. Record primary-ready and full-topology-ready times separately.

### P3: Verified Fence, Endpoints And Manual Deployment

Inventory all writers, readers, workers and jobs; obtain cutover approval. P3-S01 verifies the same run-scoped
P0 quarantine on both old DBs and requires existing-session closure confirmation. It neither changes source
SGs again nor stops the source. **No endpoint switching before verified isolation and session closure.**

P3-S02 offers automatic CLI endpoint update or read-only verification of a custodian's manual update. Both
display the primary/replica host pair. Review the selected secret and run; any apply requires the matching
P3-S01 record and explicit confirmations, including `UPDATE-ENDPOINTS`. Change only `DB_HOST` and
`DB_REPLICA_HOST`; preserve `DB_NAME`, `DB_USER`, `DB_PASSWORD` and unrelated fields, and record version IDs.

Default and range execution (including plain `S3` and `S3 --from P3-S01 --to P5`) calls P3-S02 with `--apply`
so it reaches the fence check and approval prompt instead of stopping after preview. This is not automatic
approval. A single `--only P3-S02` remains preview-only unless `--apply` is supplied; explicit `--preview`
is read-only. For step-by-step execution, use the `--apply` command below.

```bash
bash iac/lab/bb3-db/bb3-run.sh S3 --only P3-S01
bash iac/lab/bb3-db/bb3-run.sh S3 --only P3-S02 --apply
bash iac/lab/bb3-db/bb3-run.sh S3 --only P3-S03
```

The app owner performs the approved external deploy/restart so tasks load the new endpoints. P3-S03 does
not deploy: automatic mode is unavailable and stops without action. Manual attestation requires app-owner
identity, one sanitized multiline deployment/convergence log, and confirmation that all expected services/tasks
converged. The helper requires no separate commit SHA; the external procedure still controls its own version
approval. Keep any jobs paused for cutover under app-owner control until validation permits resumption.

### P4: Health T8 And Business Validation T9

```bash
bash iac/lab/bb3-db/bb3-run.sh S3 --only P4-S01
bash iac/lab/bb3-db/bb3-run.sh S3 --only P4-S02
```

After deployment, the app owner confirms the running app loaded the restored endpoints and passed an
application-level DB health check. Supply the actual T0; record UTC **T8** and health evidence. RDS `available`,
configuration parity, direct operator login or green deployment alone is not T8. Failure leaves T8 pending
and the Service RTO clock running.

Then confirm both intended DB paths and a successful business transaction/readback. Record app owner,
UTC **T9**, pass/fail and transaction reference, without credentials or business payloads. Missing approval,
reference or timestamp leaves validation incomplete. Failure after T8 does not erase the health milestone,
but does block business recovery. Report **Service RTO = T8-T0**, **business validation = T9-T8**, and
**total elapsed = T9-T0**, even when business validation adds 5-10 minutes. RPO remains a separate measure.

### Closeout Commands: T10 And P5

After P4-S02, run these as separate steps. They use the saved `BB3_DR_ID` (or accept an
explicit `--run-id DR-ID`); they never select `latest`.

```bash
bash iac/lab/bb3-db/bb3-run.sh S3 --only P4-G4
bash iac/lab/bb3-db/bb3-run.sh S3 --only P5
```

P4-G4 validates matching incident, cutover, fence, deployment, T8 and successful T9 journals
before prompting. It prints the compact timeline, RTO PASS/MISS, and saved evidence references.
Provide approver name/role and the actual T10 declaration time (Enter accepts current UTC).
No ticket/change reference is requested. Remaining restrictions default to `none` on Enter. Type
`DECLARE-RESTORED` to attest that the displayed T0/T8/T9 references were reviewed and approve
the record. Type `EDIT` instead to replace references, then provide the same approval token.
The helper writes immutable
`evidence/bb3-secret-endpoints/<DR-ID>/closeout.json`; it does not change T8/T9 or make AWS calls.
Console output shows a compact timeline and the RTO PASS/MISS result; detailed limitations are
retained in the closeout record and package summary instead of repeated during prompts.

P5 requires that closeout record and completes without additional input. It reuses the saved closeout
approver as evidence owner and writes to Git-ignored `evidence/bb3-packages`. It omits `app-deploy.log`
by default; the original log stays in the live run directory and no automatic review is claimed.
There are no owner/destination, log-inclusion or `PACKAGE-EVIDENCE` prompts. The helper creates a frozen allowlisted
snapshot, `summary.md`, SHA-256 `manifest.json`, `evidence.tar.gz`, checksum and
`evidence-package.json` receipt. A verified existing package is never overwritten. Packaging
does not upload evidence or independently verify owner attestations. Config/secrets, raw baseline
API data and external log/reference targets are not automatically copied; include approved
supporting evidence separately. RPO is not independently measured. Do not invent missing T10,
evidence locations, or milestone timestamps. Resume jobs only under app-owner approval.

Keep recorded milestone times including T0/T1/T2/T4/T5/T6/T7/**T8**/T9/T10, final hashes,
RPO limitations, replica readiness, failures/delays, reconciliation, target misses and
postmortem actions with owners/due dates.

### Failback: FB-01 Through FB-07

Do not restart plain `S3`; it begins discovery and fault injection, not failback. Obtain a separate
approved change window and data-owner decision first. Endpoint failback does not copy writes back. Reconcile
and validate restored-primary writes, or obtain explicit approval of the identified sandbox data loss; record
owner, decision, affected interval and evidence reference. Do not assume the original pair is current. Keep
it quarantined and retain restored DBs/snapshots while approval is pending.

FB labels are manual worksheet checkpoints, not runner IDs. Use the explicit completed cutover run ID,
never `latest`, which could select another drill:

```bash
DR_ID='{{COMPLETED_CUTOVER_DR_ID}}'
```

For one guided process through failback validation/sign-off, use:

```bash
bash iac/lab/bb3-db/bb3-run.sh S3 --failback "$DR_ID"
```

It runs FB-01 endpoint preview, FB-02 restored-pair fence/session confirmation, FB-03 guarded endpoint
apply, FB-04 original-quarantine release, and FB-05 deployment/health/transaction attestations followed
by the FB-06 sign-off offer. All prompts and typed approval gates remain. The app owner must drain
consumers and perform the external deployment; this command does neither automatically. It does not
repeat P0/P2 recovery, overwrite recovery milestones, or automatically approve resource retirement.
`S3 --failback "$DR_ID" --list` previews that sequence without AWS calls. On failure it stops before
later actions; inspect journals/current state before retrying the affected step, not a fresh recovery.
If sign-off is declined, completed script steps do not imply failback sign-off. The commands below
remain available for step-by-step operation or recovery from an interruption.

Failback What/Expected descriptions follow the selected action, not the recovery-only meaning of
the step ID. The first P3-S02 is a read-only preview of restored CURRENT versus original RETURN-TO
endpoints; the later P3-S02 is guarded apply. P3-S01 separately describes restored-pair fencing,
original-pair release, or detached-SG cleanup. Deployment/health/transaction descriptions refer to
the original endpoint pair and supplemental failback evidence, not new recovery T8/T9 milestones.

#### FB-01: Review Return Endpoints

The explicit `--failback "$DR_ID"` selection reuses that cutover journal's saved secret name
and run ID; there is no second secret/run selector. The helper still describes the secret and
checks its account/region before previewing. Verify CURRENT restored primary/replica hosts and
RETURN TO original hosts. Preview does not reconcile data or deploy:

```bash
bash iac/lab/bb3-db/bb3-run.sh S3 --only P3-S02 --failback "$DR_ID" --preview
```

#### FB-02: Drain And Fence The Restored Pair

App owner pauses/drains writers, readers, workers and jobs for this separate failback outage. Verify isolation
and existing-session closure on the restored pair before switching endpoints; keep the original pair quarantined.

P3-S01 failback creates or reuses the restored pair's run-scoped no-ingress SG after approval. It saves
the prior SG sets in `failback-network-fence.json`, submits both attachments before waiting, verifies
both are active, and requires separate session-closure confirmation. Resume reuses the journal.
This path has passed mocked tests, not live failback certification. Do not fabricate a journal,
bypass the gate, stop a replica, or stop a primary with replicas. If SG creation is interrupted before
journaling, reconcile the existing group manually rather than blindly creating another one.

```bash
bash iac/lab/bb3-db/bb3-run.sh S3 --only P3-S01 --failback "$DR_ID"
```

#### FB-03: Switch Both Endpoint Keys

Only after FB-02 passes, review the return plan and type `FAILBACK-ENDPOINTS` when approved. The helper
reuses the secret/run selection from the saved cutover journal and merges saved endpoints into the latest
secret version, preserving rotated credentials and unrelated fields:

```bash
bash iac/lab/bb3-db/bb3-run.sh S3 --only P3-S02 --failback "$DR_ID" --apply
```

#### FB-04: Release Original Quarantine

Only after endpoint failback is journaled, reverify the restored fence and session closure. The helper
freshly checks restored topology, quarantine ownership/no-ingress and exclusive active attachments;
missing attestations or drift block original-source release. With typed
`RELEASE-SOURCE-QUARANTINE`, restore and verify the saved original SG sets, then delete the temporary source
quarantine SG. The restored pair must remain fenced:
RDS `available` alone does not prove SG changes have applied. The helper checks each original DB's
exact saved SG IDs and active attachment status, retrying up to 24 checks with five-second intervals.
If verification remains incomplete, the source quarantine SG is retained and release stops. Inspect the
reported attachments, then retry only this release command; already-restored SG sets are not resubmitted.

```bash
bash iac/lab/bb3-db/bb3-run.sh S3 --only P3-S01 --failback "$DR_ID" --release-quarantine
```

#### FB-05: Redeploy And Validate Manually

The external BB3 application repository is not part of this framework, so the app owner performs deployment
using the approved application procedure; the helper never claims or runs an automatic deployment. P3-S03
offers option 1, which reports automatic deployment unavailable and exits without action, or option 2 after
manual deployment is complete. Option 2 captures a sanitized deployment/convergence log and records the app
owner and original endpoint pair in separate ignored `failback-app-deploy.*` files. Do not include credentials,
secret values, or customer/business payloads.

```bash
bash iac/lab/bb3-db/bb3-run.sh S3 --only P3-S03 --failback "$DR_ID"
```

After deployment, confirm health on the original primary/replica pair and provide a health evidence reference
plus the actual UTC check time (Enter defaults to current UTC). Then confirm a successful business transaction
and readback, providing only a non-secret reference and its actual UTC time:

```bash
bash iac/lab/bb3-db/bb3-run.sh S3 --only P4-S01 --failback "$DR_ID"
bash iac/lab/bb3-db/bb3-run.sh S3 --only P4-S02 --failback "$DR_ID"
```

These commands write separate `failback-app-health.json` and `failback-app-e2e.json` local journals. They
require the matching completed failback, released original-source fence, attached restored-pair quarantine,
and owner-confirmed restored-pair fence/session closure. The original recovery `app-deploy.json`, T8/T9
journals, and measurements are not changed. The original P5 package is frozen before failback; these
supplemental records are local evidence and are not added to that snapshot.

#### FB-06: Declare Failback Complete

P4-S02 with `--failback "$DR_ID"` now offers FB-06 immediately after saving the transaction. If the
transaction already exists, rerun that same command: it reviews the saved reference/time without asking
for a new transaction or overwriting it. Enter at the sign-off offer leaves approval pending.
Review the displayed saved deployment, health and transaction references and confirm the matching app owner,
then type `SIGN-OFF-FAILBACK`. The helper reuses those saved references without asking for them again;
missing or invalid prior evidence still blocks sign-off. This writes an immutable local `failback-signoff.json`
with UTC approval time and hashes of the supporting local journals/log. External references are owner
attestations, not independently fetched or verified. Existing supplemental sign-off references are preserved;
this flow does not replace placeholder inputs with actual evidence. Do not approve prompt tests as real recovery.

The following cleanup offer defaults to No. Sign-off never authorizes deletion. The standalone
retirement command below has a separate resource preview and typed deletion gate. Existing sign-off
records are never overwritten; invoke retirement directly when sign-off is already saved.
Record completion time/evidence through the approved incident process, then resume approved jobs.
On failure, keep jobs paused and follow the separately approved contingency plan. Do not un-fence both pairs.

#### FB-07: Retain And Clean Up Under Approval

Retain evidence and restored DBs/snapshots until reconciliation and retention decisions are signed off.
Use the approved IaC/ownership cleanup process for billable resources: save the plan, review it, obtain
approval, then apply that plan. Endpoint failback alone never authorizes deleting restored DBs or remaining SGs.

**Approved script-only exception:** for this run's restored pair and quarantine SG only, the owner
approved standalone AWS CLI retirement instead of a new Terraform stack. Other cleanup remains IaC-only.

```bash
bash iac/lab/bb3-db/retire-restored.sh --failback "$DR_ID"
```

This command requires matching immutable sign-off evidence hashes, the signed-off original endpoint
pair still serving in the current secret, exact restored run tags/resource IDs and verified quarantine.
Run this manual command after completed failback sign-off; no minimum waiting period is enforced,
and it is not automatically scheduled. Resource deletion still requires explicit retirement approval.
It previews the replica, primary, quarantine SG, temporary snapshot and exact restored automated-backup
resource IDs. Supply the matching
app owner and actual retirement/data-retention approval reference, then type `RETIRE-RESTORED-PAIR`.
Enter cancels; approval never defaults to Yes. It creates and verifies a manual snapshot of the restored
primary before deleting the replica, waits for its absence, then deletes the restored primary. It holds
the recovery data until DB deletion finishes and deletes the quarantine SG only after no DB or ENI remains
attached. Under that same approval, it then deletes automated backups for the exact saved restored DB
resource IDs and the verified retirement-created snapshot. There is no separate backup approval.
This permanently removes that restored pair's recovery data. It does not
disable deletion protection, detach SGs from retained DBs, delete original DBs, shared networking, secrets,
other SGs, original DB backups, the source restore snapshot, unrelated snapshots/backups or evidence.

Progress is saved separately in ignored `retirement.json`, without changing sign-off journals or the
frozen P5 package. Rerun the same explicit command after an interrupted waiter or delayed ENI detachment;
recorded resource identities must still match. Unexpected disappearance, changed endpoints/evidence or
additional replicas/attachments block further deletion. A completed retry verifies resource absence and
scoped backup/snapshot absence without mutations. Pending AWS backup deletion leaves retirement incomplete;
resume the same command without recreating a snapshot already marked for purge. Old retained-backup
journals require a new scope review and the existing typed retirement approval before purge. Local mocked
tests do not certify a live retirement.

There are two quarantine SG cleanup stages:

- **Original-source quarantine:** FB-04 restores the saved original SG sets and deletes that temporary
  source quarantine SG after verification. The original pair then serves the application again.
- **Restored-pair quarantine:** keep it attached while the restored DBs are retained. After app failback
  is signed off and the restored pair is retired through the separately approved cleanup plan, delete
  the now-detached group with the command below. Cleanup requires matching owner-confirmed
  `failback-app-deploy.json`, `failback-app-health.json`, and `failback-app-e2e.json` records, plus
  app-owner evidence and typed approval. The helper verifies detachment and deletes only the restored-pair
  quarantine SG; it never detaches or deletes DBs. Never detach it from retained DBs merely to delete it.

```bash
bash iac/lab/bb3-db/bb3-run.sh S3 --only P3-S01 --failback "$DR_ID" --cleanup-failback-quarantine
```

Cleanup requires the explicit run ID (not `latest`), completed endpoint failback, released source
quarantine, matching restored quarantine ownership, no DB or ENI attachments, all three matching failback
app journals, app-owner sign-off and evidence reference, and typed `DELETE-FAILBACK-QUARANTINE`. It does
not delete DBs/snapshots or restore SG attachments. Successful deletion is verified and journaled; a
verified deleted retry makes no changes.

### Historical Results: Not Current Status

These are prior observations, not live attestations or proof that the workflow above has now completed:

- **DR-20261020-0756-uat-BB3-S3, endpoint update only:** preview matched old `DB_HOST`/`DB_REPLICA_HOST`
  and displayed the restored pair. After exact secret/run confirmation and `UPDATE-ENDPOINTS`, version
  `14bd1175-cb4c-4ba2-9ed6-de521641e891` became `AWSCURRENT`. Only endpoint keys changed; password and
  unrelated fields were verified unchanged. Journal:
  `evidence/bb3-secret-endpoints/DR-20261020-0756-uat-BB3-S3/cutover.json`. This completed the endpoint update,
  not recovery: no application deployment, fencing or business E2E was performed. No SSM Automation or new
  Terraform was deployed for that endpoint update.
- A prior read-only SG check still found PostgreSQL ingress from the VPC CIDR and SSM tunnel host. That old
  pair was not confirmed isolated. The newer P0/P3 workflow is not retroactive proof of fencing.
- The user supplied transaction reference **12345** and selected that both restored endpoints were verified,
  but app-owner name and UTC completion time were absent. That record is incomplete: it does not establish
  T9 or application recovery. No credentials or business payloads were supplied.
- A one-time SSM tunnel test passed read-only logins to old primary, restored primary, old replica and new
  replica; tunnels were closed. At that report, the EC2 host, peering, routes and host-only PostgreSQL ingress
  remained active pending separately approved cleanup. This is not a current resource inventory.

---

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