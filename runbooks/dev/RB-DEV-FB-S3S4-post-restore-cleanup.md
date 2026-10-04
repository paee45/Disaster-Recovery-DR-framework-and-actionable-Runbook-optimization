# RB-DEV-FB-S3S4 — Post-Restore Cleanup (DEV)

| Field | Value |
|---|---|
| Type | Ticketed task within 2 business days of RB-DEV-S3/S4 (full cutover) |
| Goal | The restored instance is the official DEV primary: settings, IaC and monitoring aligned; old instance removed |

```bash
source env/dev.env && source automation/scripts/dr-lib.sh && dr_init FB-S3S4
export OLD_DB=app-pg-dev NEW_PRIMARY=<RESTORED_DB>
dr_set_target "$NEW_PRIMARY"
```

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| P1-S01 | `./automation/scripts/rds-config-parity.sh $OLD_DB $NEW_PRIMARY` → fix the remaining diffs (backup retention, tags incl. the AWS Backup selection tag, log exports) | Engineer | 10 | No diffs |
| P1-S02 | Re-enable secret rotation, if DEV uses it (CP03-S05) | Engineer | 2 | On |
| P1-S03 | **IaC adoption** ([CP-03 §3](../common/CP-03-restored-instance-config-parity.md#3-iac-adoption-terraform-example)) + `env/dev.env` PR (`PRIMARY_DB=$NEW_PRIMARY`) | Engineer | 20 | Clean plan |
| P1-S04 | Re-point alarms/dashboards (if any) | Engineer | 5 | OK |
| P2-S01 | Delete OLD_DB after 3 days: disable deletion protection → `aws rds delete-db-instance --db-instance-identifier $OLD_DB --final-db-snapshot-identifier ${OLD_DB}-final-$(date -u +%Y%m%d)` | Engineer | 5 | Deleted |
| P2-S02 | Note learnings for the automation (script bugs, missing flags) as tickets; they flow to the UAT/PROD runbooks | Engineer | 5 | Tickets |
