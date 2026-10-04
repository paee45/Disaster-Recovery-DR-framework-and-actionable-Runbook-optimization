# RB-UAT-FB-S3S4 — Post-Restore Normalisation (UAT)

| Field | Value |
|---|---|
| Type | Standard change within 5 business days of RB-UAT-S3 / RB-UAT-S4 mode A |
| Start → end | `RESTORED_DB` primary without a replica; old primary + old replica fenced → **primary + new replica**, parity, IaC, old instances removed |

```bash
source env/uat.env && source automation/scripts/dr-lib.sh && dr_init FB-S3S4
export OLD_DB=app-pg-uat OLD_REPLICA=app-pg-uat-replica NEW_PRIMARY=<RESTORED_DB>
dr_set_target "$NEW_PRIMARY"
```

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P1-S01 | New replica: `aws --profile $AWS_PROFILE --region $AWS_REGION rds create-db-instance-read-replica --db-instance-identifier ${NEW_PRIMARY}-replica --source-db-instance-identifier $NEW_PRIMARY --db-instance-class $DB_INSTANCE_CLASS --db-subnet-group-name $DB_SUBNET_GROUP --vpc-security-group-ids $DB_SG --db-parameter-group-name $DB_PARAM_GROUP --copy-tags-to-snapshot` | DBA | 5 (+ build) | `replicating` |
| P1-S02 | RO secret → new replica (`dr-secret-cutover.sh apply` with `TARGET_DB=${NEW_PRIMARY}-replica SECRET_ID=$SECRET_ID_RO`) | Executor | 5 | Readers rolled |
| P1-S03 | Pre-flight on the new pair (`dr-preflight.sh replica`) | Executor | 3 | PASS |
| P2-S01 | [CP-03](../common/CP-03-restored-instance-config-parity.md) complete (parity, monitoring, rotation, backup tag, IaC adoption) | SRE | 45 | Clean plan |
| P2-S02 | CDC/ETL/test-automation pipelines that reference the instance re-pointed; `env/uat.env` + CMDB PR | SRE | 15 | Merged |
| P3-S01 | Delete the old replica (`--skip-final-snapshot`; replicas cannot have one) and OLD_DB (final snapshot) after 7 days | DBA | 10 | Deleted |
| P3-S02 | CP-05 evidence (`type=failback`), close the change, notify the UAT users | Scribe | 10 | Closed |
