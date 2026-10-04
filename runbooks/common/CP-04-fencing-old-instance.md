# CP-04 — Fencing the Old Instance

**Why:** with secret-based cutover, any pod that has not restarted yet, any CronJob, any external client or any
admin script can still write to OLD_DB. Writes there after the cutover are **lost or split-brain**.
**Used by:** S2 (old primary may be partly alive), S3/S4 (old primary is usually fully alive). **Not S1.**

Use one or more levels, from the lightest to the strongest:

| Level | Method | Reversible | Keeps OLD_DB readable for reconciliation | Command |
|---|---|---|---|---|
| F1 | **Make the DB read-only** and kill sessions | Yes | Yes | `./automation/scripts/dr-fence-instance.sh readonly $OLD_DB` |
| F2 | **Quarantine SG** (no inbound) attached to OLD_DB | Yes | DBA only, via a bastion SG rule | `./automation/scripts/dr-fence-instance.sh quarantine $OLD_DB` |
| F3 | **Stop** the instance (`stop-db-instance`; auto-starts after 7 days!) | Yes | No (start it to read) | `aws rds stop-db-instance --db-instance-identifier $OLD_DB --db-snapshot-identifier ${OLD_DB}-fence-$(date -u +%Y%m%d%H%M)` |

**Recommended by scenario:**
| Scenario | When | Level |
|---|---|---|
| S2 unplanned | **Before promotion** (if OLD_DB is reachable) | F2 (it may be unresponsive to SQL). If unreachable → record a waiver and re-try fencing as soon as it is reachable |
| S2 planned (maintenance / FB option B) | Before promotion | F1 (drain) → wait for lag 0 → promote |
| S3/S4 full cutover | **Right after CP01-S07** (rollouts done), *before* CP-02 | F1 immediately; F2 once reconciliation data is extracted. F1 *before* the cutover is also valid: it stops further damage (corruption still running) at the cost of read-only errors until the cutover |
| S4 surgical repair | Not applicable (OLD_DB stays primary) | — |

> **Note F1:** `default_transaction_read_only` is a *default* that a client can override. F1 is a guard against
> stray writes, not a security control. Use F2 for a hard fence.

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| CP04-S01 | Snapshot the old instance **before** any destructive action, if it is reachable: `aws rds create-db-snapshot --db-instance-identifier $OLD_DB --db-snapshot-identifier ${OLD_DB}-pre-fence-$(date -u +%Y%m%d%H%M)` (can run ‖ with the fence) | DBA | 1 | Snapshot creating |
| CP04-S02 | Apply the fence level chosen in the table above; the script saves the before-state (SG IDs, parameter values) into evidence | Executor | 2 | `fence: OK level=Fx` |
| CP04-S03 | Verify: `./automation/scripts/dr-verify.sh connections` shows 0 app sessions on OLD_DB (F1/F2) | DBA | 1 | 0 |
| CP04-S04 | Record the fence state and any waiver in the timeline: `dr_mark FENCE "level=F2 waiver=none"` | Scribe | — | Recorded (input to reconciliation) |

**Un-fence** (rollback or reconciliation): `./automation/scripts/dr-fence-instance.sh restore $OLD_DB` restores the saved SGs / read-only setting.
