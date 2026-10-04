# RB-PROD-FB-S1 — Optional AZ Rebalance after a Multi-AZ Failover (PROD)

| Field | Value |
|---|---|
| Type | **Planned change**, maintenance window, standard change `{{CHG}}` |
| Use only if | The PIR or P2-S06 showed that DB placement in the new AZ breaks the latency SLO or adds material cross-AZ cost, **and** spreading app pods across AZs (preferred fix) is not enough |
| Impact | One more Multi-AZ failover: ~1–2 min of write unavailability. RPO 0 |
| Secret change | None |

> Preferred long-term fix: spread app replicas across all AZs (`topologySpreadConstraints`). Then DB AZ placement
> does not matter and this runbook is never needed.

```bash
source env/prod.env && source automation/scripts/dr-lib.sh && dr_init FB-S1 && dr_set_target "$PRIMARY_DB"
```

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P1-S01 | Planned-maintenance comms T−5 business days (customers, if impact ≥ 1 min is visible), T−2 days internal ([05-planned-drill-notices](../../templates/communications/05-planned-drill-notices.md)) | Comms | — | Sent |
| P1-S02 | Pre-check: `MultiAZ=true`, `SecondaryAvailabilityZone` = the **preferred** AZ, status `available`, no pending modifications, replica `replicating` | DBA | 2 | All true |
| P1-G1 ⛳ | Go (change owner + DBA) | IC | 1 | Recorded |
| P2-S01 | `dr_mark T4` then `aws rds reboot-db-instance --db-instance-identifier $PRIMARY_DB --force-failover` | Executor | 1 | API 200 |
| P2-S02 | `aws rds wait db-instance-available --db-instance-identifier $PRIMARY_DB`, then confirm the AZ = preferred. `dr_mark T5` | Executor | 3 | AZ swapped |
| P2-S03 | Same checks as RB-PROD-S1 P2-S01 … P2-S05 (restart only if errors persist) | App + DBA | 15 | Pass |
| P2-S04 | CP-05 evidence (label `type=planned`), close the change; send the "maintenance completed" comms | Scribe | 10 | Done |
