# CP-04 — Fencing the Old Instance

**Why:** with secret-based cutover, any pod that has not restarted yet, any CronJob, any external client or any
admin script can still write to OLD_DB. Writes there after the cutover are **lost or split-brain**.
**Used by:** S2 (old primary may be partly alive), S3/S4 (old primary is usually fully alive). **Not S1.**

Use one or more levels, from the lightest to the strongest:

| Level | Method | Reversible | Keeps OLD_DB readable for reconciliation | Command |
|---|---|---|---|---|
| F1 | **Make the DB read-only** and kill sessions | Yes | Yes | `./automation/scripts/dr-fence-instance.sh readonly $OLD_DB` |
| F2 | **Quarantine SG** (no inbound) attached to OLD_DB | Yes | DBA only, via a bastion SG rule | `./automation/scripts/dr-fence-instance.sh quarantine $OLD_DB` |
| F3 | **Request stop**, overlap with rollout, then confirm stopped (auto-starts after 7 days!) | Start requires separate approval | No (start it to read) | `./automation/scripts/dr-fence-instance.sh stop "$OLD_DB"`, then `wait-stopped "$OLD_DB"` |

**Recommended by scenario:**
| Scenario | When | Level |
|---|---|---|
| S2 unplanned | **Before promotion** (if OLD_DB is reachable) | F2 (it may be unresponsive to SQL). If unreachable → record a waiver and re-try fencing as soon as it is reachable |
| S2 planned (maintenance / FB option B) | Before promotion | F1 (drain) → wait for lag 0 → promote |
| S3/S4 full cutover | After target validation and cutover approval, immediately before Secret update | Runner: F1 read-only or F3 stop request. With F3, overlap stopping with Secret update/rollout; confirm stopped before E2E/T9. F2 remains available through the fencing helper. |
| S4 surgical repair | Not applicable (OLD_DB stays primary) | — |

> **Note F1:** `default_transaction_read_only` is a *default* that a client can override. F1 is a guard against
> stray writes, not a security control. Use F2 for a hard fence.

### Optional asynchronous stop in the runner

Choose `stop` at the fence prompt (`FENCE=stop`). S3 requests stop at P3-S01, cuts over at P3-S02, completes rollout at
P3-S03, and confirms stop at P4-S01. S4 mode A requests stop at P3A-S02, cuts over/rolls at P3A-S03, and confirms stop at
P3A-S04. E2E rechecks the stop state before recording T9. All preparation and approvals happen before the stop request;
there is no stop waiter between the request and endpoint update. SQL target-login checks still run as part of cutover.

This requires AWS RDS permissions, not the PostgreSQL master password. The helper only accepts standalone RDS PostgreSQL
without read replicas, a replica source, or cluster membership. Unsupported topologies fail before requesting stop.
The source may still accept writes while stopping; overlap is not atomic fencing. `STOP_REQUESTED` is not proof of isolation.
`FENCE` is recorded only after the waiter succeeds and a fresh describe confirms `stopped`, using the observation time as a
conservative loss-end timestamp. Wait failures block E2E/T9; a failed cutover does not automatically restart the old DB.

`DR_ENV=local` refuses Moto-only F3. For a physical fixture test, finish target validation and cutover approval, run
`bash iac/local.sh db old stop` on the host (review/apply its saved Terraform plan), then resume the same DR run.
The runner requires host inspection evidence and an unreachable original PostgreSQL endpoint. No master password
or tools-container Docker socket is used. This staged local test does not simulate asynchronous RDS stop timing.
Offline regression: `bash tests/local/test-stop-fencing.sh` (Bash 4+). See the local IaC guide for start/failback controls.

For failback from F3, separately approve starting the original under controlled isolation, reconcile target writes, and
verify writable app access before endpoint failback. `restore` only undoes F1/F2 and refuses F3 evidence; it never starts
an instance. Do not stop the restored DB until failback and consumer verification finish and retention is approved.

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| CP04-S01 | Snapshot the old instance **before** any destructive action, if it is reachable: `aws --profile $AWS_PROFILE --region $AWS_REGION rds create-db-snapshot --db-instance-identifier $OLD_DB --db-snapshot-identifier ${OLD_DB}-pre-fence-$(date -u +%Y%m%d%H%M)` (can run ‖ with the fence) | DBA | 1 | Snapshot creating |
| CP04-S02 | Apply the fence level chosen in the table above; the script saves the before-state (SG IDs, parameter values) into evidence | Executor | 2 | `fence: OK level=Fx` |
| CP04-S03 | Verify: `./automation/scripts/dr-verify.sh connections` shows 0 app sessions on OLD_DB (F1/F2) | DBA | 1 | 0 |
| CP04-S04 | Record the fence state and any waiver in the timeline: `dr_mark FENCE "level=F2 waiver=none"` | Scribe | — | Recorded (input to reconciliation) |

**Un-fence** (rollback or reconciliation): `./automation/scripts/dr-fence-instance.sh restore $OLD_DB` restores the saved SGs / read-only setting.
