# CP-06 — Post-Incident Review (Post-Mortem)

Template: [`templates/reports/post-incident-review.md`](../../templates/reports/post-incident-review.md). Blameless. Use the facts from
the evidence bundle and timeline, not from memory.

## Universal questions
1. **Detection:** T0 → first alarm → page → ack. Did the right alarm fire? Was there an earlier signal?
2. **Decision:** T1 → G1. Was the right scenario chosen (see the decision tree)? What slowed the decision?
3. **Execution:** which steps deviated from the runbook, and why? Which manual steps could be automated?
4. **Cutover:** T6 (secret) → T7 (rollouts). Which consumers were not covered by Reloader?
5. **Comms:** time to the first message per audience; were updates on cadence?
6. **Data:** RPO actual vs target; is reconciliation complete and signed off?
7. **Residual risk:** what protection is missing until the FB runbook completes (no replica, single-AZ, rotation off)?

## Scenario-specific questions

| Scenario | Questions |
|---|---|
| **S1 Multi-AZ** | What triggered the failover (RDS event message: host failure, storage, OS patching, instance modify, `reboot --force-failover`)? Actual impact vs AWS failover time: if apps took longer than ~2 min, why (DNS caching in the JVM/driver, pools without validation, liveness restarts)? Did the read replica keep replicating? Is the app now cross-AZ to the DB (latency/cost)? Was AWS Health notified? Was the failover expected (maintenance) but not communicated? |
| **S2 Replica promote** | Lag at promotion and real data loss? Was fencing possible, and if not, were there writes to OLD_DB after promotion? Promotion duration? Did reads (RO secret) keep working? How long was PROD without Multi-AZ/replica? Root cause of the primary loss? |
| **S3 Snapshot** | Why was PITR not usable? Snapshot age vs RPO, and is daily enough? Restore duration vs DB size (feeds the RTO model)? Parity gaps found by CP-03? Password mismatch? Lazy-loading impact? |
| **S4 PITR** | How was the restore time chosen, and how accurate was it (too early = extra loss; too late = corruption kept)? Was surgical repair considered? Which writes after the restore point were lost or re-applied? What allowed the bad change (migration review, guardrails, permissions)? |

## Outputs
- Action items, each with type (prevent / detect / mitigate / process), owner, due date and ticket
- Runbook PRs (version bump + change-log row referencing the PIR)
- Updated RTO/RPO model (restore time per GB, promotion time) in [`docs/04`](../../docs/04-rpo-rto-measurement.md)
- [Post-Mortem / RCA Ready] comms per audience
