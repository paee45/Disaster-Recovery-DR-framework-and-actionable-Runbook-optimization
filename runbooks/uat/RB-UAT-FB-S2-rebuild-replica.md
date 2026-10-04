# RB-UAT-FB-S2 — Post-Promotion Failback: Rebuild Replica (UAT)

| Field | Value |
|---|---|
| Type | Standard change within 5 business days of RB-UAT-S2 |
| Start → end | Promoted `app-pg-uat-replica` standalone, no replica → **primary + new replica** (UAT standard: no Multi-AZ), IaC in sync |
| Model | **Forward-fix** (keep the promoted instance as primary). Return to the original identifier only if tooling requires it (then follow RB-PROD-FB-S2 Phase 3B without the Multi-AZ steps) |

```bash
source env/uat.env && source automation/scripts/dr-lib.sh && dr_init FB-S2
export OLD_DB=app-pg-uat NEW_PRIMARY=app-pg-uat-replica
dr_set_target "$NEW_PRIMARY"
```

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P1-S01 | New replica: `aws --profile $AWS_PROFILE --region $AWS_REGION rds create-db-instance-read-replica --db-instance-identifier app-pg-uat-replica2 --source-db-instance-identifier $NEW_PRIMARY --db-instance-class $DB_INSTANCE_CLASS --db-subnet-group-name $DB_SUBNET_GROUP --vpc-security-group-ids $DB_SG --db-parameter-group-name $DB_PARAM_GROUP --copy-tags-to-snapshot` | DBA | 5 (+ build) | `replicating` |
| P1-S02 | RO secret → new replica: `TARGET_DB=app-pg-uat-replica2 SECRET_ID=$SECRET_ID_RO ./automation/scripts/dr-secret-cutover.sh apply` | Executor | 5 | Readers rolled by Reloader |
| P1-S03 | Pre-flight on the new pair: `PRIMARY_DB=$NEW_PRIMARY REPLICA_DB=app-pg-uat-replica2 ./automation/scripts/dr-preflight.sh replica` | Executor | 3 | PASS |
| P2-S01 | [CP-03](../common/CP-03-restored-instance-config-parity.md) (parity, monitoring re-point, **re-enable rotation**, backup tag, **IaC adoption**) | SRE | 45 | `terraform plan` clean |
| P2-S02 | Update `env/uat.env` (PRIMARY_DB / REPLICA_DB) + CMDB via a PR | SRE | 5 | Merged |
| P2-S03 | Reconciliation (only if UAT users report missing data and the lag was > 0): `30-reconciliation-hints.sql` on the fenced OLD_DB | DBA | — | Done / not needed |
| P3-S01 | Decommission OLD_DB after 7 days: disable deletion protection → `delete-db-instance --final-db-snapshot-identifier ${OLD_DB}-final-<date>` | DBA | 5 | Deleted |
| P3-S02 | CP-05 evidence (`type=failback`), close the change, inform the UAT users | Scribe | 10 | Closed |
