# RB-UAT-S2 — Read Replica Promotion (UAT)

| Field | Value |
|---|---|
| Version / owner | v1.0-draft / `{{SRE_OWNER}}` · Reviewed: SRE lead · Approved: CTO · Gate approvers: SRE on-call + QA lead |
| Before → after | `app-pg-uat` (single-AZ, lost) + `app-pg-uat-replica` → **`app-pg-uat-replica` = standalone primary** (single-AZ, as UAT standard) |
| Endpoint | **Changes** → [CP-01](../common/CP-01-secret-endpoint-cutover.md) → ESO → Reloader |
| Targets | RPO target 24 h (expected = replica lag) · RTO target 30 min |
| Approvals | 1 (SSM `MinRequiredApprovals=1`) |
| Comms | Internal chat + UAT users / implementation projects (email) |

> UAT mirrors RB-PROD-S2 (except Multi-AZ). No drills are scheduled; if testing is approved later, this is the safest place to
> rehearse the PROD S2 path (`DR_MODE=planned` with a drain to lag 0).

**Use when:** the UAT primary is lost (instance/AZ failure; **no Multi-AZ** in UAT, so an AZ failure takes the primary down)
and the replica data is correct. **Not for** data damage → [RB-UAT-S4](RB-UAT-S4-pitr.md).

```bash
source env/uat.env && source automation/scripts/dr-lib.sh && dr_init S2
dr_set_target "$REPLICA_DB"
```

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P1-S01 | Open the incident (SEV3) + channel `#inc-<date>-uat-rds`; post [Investigating] internally. `dr_mark T1`, `dr_mark T0 --at <impact>` | SRE on-call | 3 | Open |
| P1-S02 ‖ | Email the UAT users / project leads ([Investigating], `[UAT]` tag) if the expected downtime is > 30 min | Comms / QA lead | 5 | Sent |
| P1-S03 | Confirm the scenario: primary status/events; the data is correct | DBA | 3 | `DECISION: S2` |
| P1-S04 | `dr_run preflight ./automation/scripts/dr-preflight.sh replica` | Executor | 3 | PASS / waivers |
| P1-G1 ⛳ | GO (SRE on-call + QA lead). The alternative is to wait for the AWS recovery of the primary when no UAT testing is time-critical. `dr_mark T2` | SRE on-call | 5 | Recorded |
| P2-S01 ‖ | [CP-04](../common/CP-04-fencing-old-instance.md) F2 on `$PRIMARY_DB` if the API accepts it; otherwise waiver | Executor | 3 | Fenced / waiver |
| P2-S02 ‖ | CP01-S01…S03 (inventory, suspend rotation, suspend CronJobs) | Executor | 3 | Done |
| P2-S03 | Final replica state: `dr_run replica-final psql "$TARGET_DSN" -XAt -f automation/sql/10-preflight-replica.sql` | DBA | 1 | Saved |
| P2-G2 ⛳ | Point of no return (SRE on-call): approve in SSM or proceed manually | SRE on-call | 1 | Recorded |
| P2-S04 ⚠ | Promote: SSM `DR-RdsPromoteReplica` (`MinRequiredApprovals=1`) **or** `dr_mark T4; aws rds promote-read-replica --db-instance-identifier $REPLICA_DB --backup-retention-period 7` | Executor | 1 | API 200 |
| P2-S05 | `./automation/scripts/dr-verify.sh wait-promoted` → `dr_mark T5` | Executor | 5–15 | PROMOTED |
| P3-S01 | [CP-01](../common/CP-01-secret-endpoint-cutover.md) S04–S09 (incl. `$SECRET_ID_RO` → new primary) → `T6`, `T7` | Executor | 10 | Consumers on the new primary |
| P4-S01 | [CP-02](../common/CP-02-post-recovery-verification.md) S01, S03–S07 (synthetics, or the QA smoke suite) → `T9`, `T10`; [Services Restored] to the UAT users | QA lead + DBA | 20 | Pass |
| P4-S02 | [CP-03](../common/CP-03-restored-instance-config-parity.md) S01, S02, S04 (no Multi-AZ in UAT) | DBA | 15 | Parity OK |
| P4-S03 | [CP-05](../common/CP-05-evidence-and-closure.md); raise [RB-UAT-FB-S2](RB-UAT-FB-S2-rebuild-replica.md) (within 5 business days); [CP-06](../common/CP-06-post-incident-review.md) PIR ≤ 10 business days | Scribe / IC | 15 | Done |
