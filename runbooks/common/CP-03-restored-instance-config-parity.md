# CP-03 — Config Parity, Hardening & IaC Adoption of a New Primary

**Used by:** S2 (promoted replica), S3/S4 (restored instance), and every FB runbook.
**Why:** restore and promotion do **not** carry over everything. A new primary that "works" but has no backups,
no alarms, the default parameter group, or is invisible to Terraform is the **next** incident.

## 1. What is (not) carried over — check every item

| Attribute | Promote replica (S2) | Restore snapshot/PITR (S3/S4) | Action |
|---|---|---|---|
| Data, users, passwords | ✔ (current) | ✔ **as of restore point** | CP01-S04 password check |
| Instance class / storage | Replica's own settings | Pass on restore (else the snapshot's) | Pass explicitly |
| Multi-AZ | Replica's setting (usually single-AZ) | Only if `--multi-az` is passed | PROD: enforce Multi-AZ |
| Security groups | Replica's SGs | **Default VPC SG** unless `--vpc-security-group-ids` is passed | Pass explicitly ⚠ |
| Parameter group | Replica's PG | **Default PG** unless `--db-parameter-group-name` is passed | Pass explicitly ⚠ (otherwise `rds.force_ssl`, `log_*` and `shared_preload_libraries` silently differ) |
| Backup retention | Set via `--backup-retention-period` on promote | Check, then `modify` | ≥ policy (PROD 14–35 d) |
| Deletion protection | Replica's | Not set unless passed | Enable |
| Performance Insights / Enhanced Monitoring | Replica's | Must be set | Enable as before |
| CloudWatch log exports | Replica's | Pass `--enable-cloudwatch-logs-exports` | Same as before |
| IAM DB auth, CA cert (`--ca-certificate-identifier`) | Replica's | Must be set | Same as before |
| Tags (AWS Backup plan selection, cost) | Replica's | `--copy-tags-to-snapshot`; tags must be passed | ⚠ Without the backup tag, AWS Backup will **not** protect the new DB |
| Read replica(s) | None (the replica *became* primary) | None (the old replica still follows the OLD primary) | FB runbook: create a new replica |
| CloudWatch alarms / dashboards / RDS event subscriptions | **Point at the old identifier** | Same | ⚠ Re-point, or monitoring is blind |
| Datadog/Prometheus exporters, log pipelines | Old identifier/endpoint | Same | Update |
| Logical replication slots / CDC (DMS, Debezium) | Not carried over | Stale/invalid | Re-initialise the CDC consumers |
| Secrets Manager rotation | Suspended in CP01-S02 | Same | Re-enable after stabilisation |
| Terraform/CloudFormation state | Drift (unknown instance; replica resource changed) | Drift (unknown instance) | **IaC adoption** (§3) |

## 2. Steps

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| CP03-S01 | **Validate against the baseline** (restores S3/S4): `./automation/scripts/dr-restore.sh validate $TARGET_DB` compares **every** attribute of `describe-db-instances` (identity/runtime fields excluded) + every source tag + pending modifications with the baseline captured before the restore. For S2 (promoted replica) use `./automation/scripts/rds-config-parity.sh $OLD_DB $TARGET_DB` | DBA | 2 | The `DIFF` lines are the to-do list; `POLICY` lines are intended (retention floor, deletion protection) |
| CP03-S02 | Apply the missing settings: `./automation/scripts/dr-restore.sh harden $TARGET_DB` (modifies only differing settings, adds IAM roles/tags, reboots if `pending-reboot`, re-validates). Manual equivalent: `aws --profile $AWS_PROFILE --region $AWS_REGION rds modify-db-instance --db-instance-identifier $TARGET_DB --apply-immediately --backup-retention-period <n> --deletion-protection --enable-performance-insights --monitoring-interval 60 --monitoring-role-arn <arn> --cloudwatch-logs-export-configuration '{"EnableLogTypes":["postgresql","upgrade"]}' ...` and `aws --profile $AWS_PROFILE --region $AWS_REGION rds add-tags-to-resource ...` | DBA | 5 | `VALIDATED`; then `dr-restore.sh validate-pg` (pg_settings) `VALIDATED` |
| CP03-S03 | **PROD only: Multi-AZ** `aws --profile $AWS_PROFILE --region $AWS_REGION rds modify-db-instance --db-instance-identifier $TARGET_DB --multi-az --apply-immediately` (online, but adds I/O load while the standby is built; prefer a quiet period the same day) | DBA | 5 (+ async) | `MultiAZ=true`, `SecondaryAvailabilityZone` set |
| CP03-S04 | **Monitoring re-point**: alarms (`DBInstanceIdentifier` dimension), dashboards, RDS event subscription source IDs, Datadog/Prometheus config → TARGET_DB. Run `./automation/scripts/rds-config-parity.sh --alarms $OLD_DB $TARGET_DB` | SRE | 10 | Alarms for TARGET_DB exist and are `OK` (not `INSUFFICIENT_DATA`) |
| CP03-S05 | **Re-enable rotation** (if it was enabled): `aws --profile $AWS_PROFILE --region $AWS_REGION secretsmanager rotate-secret --secret-id $SECRET_ID --rotation-rules AutomaticallyAfterDays=30` (the rotation Lambda reads `host` from the secret, so it now targets TARGET_DB). Do it after T10 + 2 h | Executor | 2 | `RotationEnabled=true`; the first rotation succeeds |
| CP03-S06 | **Backups**: confirm the AWS Backup plan selects TARGET_DB (tag), take a manual baseline snapshot `aws --profile $AWS_PROFILE --region $AWS_REGION rds create-db-snapshot --db-instance-identifier $TARGET_DB --db-snapshot-identifier ${TARGET_DB}-baseline-$(date -u +%Y%m%d%H%M)` | DBA | 2 | Snapshot `available` |
| CP03-S07 | **IaC adoption** (§3) | SRE | 30 | `terraform plan` shows no destroy/replace |

## 3. IaC adoption (Terraform example)

Never `terraform apply` an un-adopted state after an incident. It may **destroy the new primary or recreate the old one**.
```bash
# 1) freeze pipelines for the DB stack (CI variable / branch protection)
# 2) point the resource at the new instance (choose one)
terraform state rm aws_db_instance.primary
terraform import aws_db_instance.primary "$TARGET_DB"
# 3) update code: identifier = "<TARGET_DB>" (or a variable), replicate_source_db removed (S2), multi_az etc.
# 4) terraform plan → must show only in-place updates; review with the DBA
# 5) for the old replica / old primary resources: `terraform state rm` and delete via the FB runbook (keeps final snapshot)
```
