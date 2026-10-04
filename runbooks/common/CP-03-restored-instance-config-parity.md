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

## 1b. Field-by-field: how each `describe-db-instances` field reaches the new instance
Single source: [`automation/scripts/rds-requests.jq`](../../automation/scripts/rds-requests.jq) (used by `dr-restore.sh`
restore / `create-like` / `harden` / `validate` and by the local test bed). Example values = the UAT instance (sanitised).

| Field (example) | Restore request | Harden (modify after) | Validate |
|---|---|---|---|
| `DBInstanceClass` db.t4g.small · `MultiAZ` false | ✔ | converge if different | ✔ |
| `VpcSecurityGroups` (3 SGs) | ✔ **all** SG ids | converge (sorted) | ✔ |
| `DBSubnetGroup` (name; 3 subnets in 1a/1b/1b) | ✔ group **name** (the group carries its subnets) | — | ✔ name, VPC, subnet ids |
| `DBParameterGroups` ev-postgres-17 | ✔ | converge; **reboot** if `pending-reboot` | ✔ incl. `in-sync` |
| `OptionGroupMemberships` default:postgres-17 | only if **custom** (default:* is automatic) | converge if custom | ✔ |
| `Endpoint.Port` 5432 (`DbInstancePort` 0) | ✔ `Port` from the endpoint (0 is never sent) | — | ✔ |
| `StorageType` gp3 · `AllocatedStorage` 20 | ✔ type; size = snapshot size (or larger baseline) | `MaxAllocatedStorage` | ✔ |
| `Iops` 3000 · `StorageThroughput` 125 | **not sent** for gp3 < 400 GiB (fixed baseline; the API rejects them); sent for io1/io2 and gp3 ≥ 400 GiB | — | ✔ (equal by design) |
| `BackupRetentionPeriod` 7 · `PreferredBackupWindow` | ✔ (CLI default would be **1 day**) | converge | ✔ |
| `PreferredMaintenanceWindow` | ✘ (API) | ✔ | ✔ |
| `BackupTarget` region · `LicenseModel` · `EngineLifecycleSupport` (extended support) · `NetworkType` · `DedicatedLogVolume` · `CACertificateIdentifier` rds-ca-rsa2048-g1 · `EnabledCloudwatchLogsExports` [postgresql] · `IAMDatabaseAuthenticationEnabled` · `PubliclyAccessible` · `AutoMinorVersionUpgrade` · `CopyTagsToSnapshot` · `DeletionProtection` | ✔ | converge where the API allows | ✔ |
| `MonitoringInterval` 60 + `MonitoringRoleArn` | ✘ (API) | ✔ | ✔ |
| `PerformanceInsightsEnabled` + KMS key + retention 7 · `DatabaseInsightsMode` standard | ✘ (API) | ✔ (as one set) | ✔ |
| `AssociatedRoles` (none in UAT) | ✘ | ✔ `add-role-to-db-instance` | ✔ |
| `TagList` | user tags ✔ · **`aws:*` never** (AWS-reserved, e.g. `aws:cloudformation:*`) | missing user tags added | user tags ✔ |
| `EngineVersion` 17.9 · `StorageEncrypted` false · `KmsKeyId` | from the **snapshot** (not settable on restore) | — (an engine diff = IC decision) | ✔ |
| `UpgradeRolloutOrder` second | not settable by any API | — | reported as INFO, not compared |
| identity/runtime: identifier, ARN, `DbiResourceId`, endpoint address, create/restorable/restart times, status, AZ, certificate `ValidTill`, monitoring resource ARN, replica lists, activity stream | — | — | ignored |

**What the UAT describe tells us (2026-10):**
- **Not encrypted at rest** (`StorageEncrypted: false`): every snapshot and restore is unencrypted too → ISO 27001 A.8.24 finding.
  Remediation: `copy-db-snapshot --kms-key-id …` then restore the encrypted copy (one-time migration, plan a window).
- **Status `stopped`**: restores still work (restore point ≤ `LatestRestorableTime`), but `pg_settings` can't be captured and AWS
  auto-starts it at `AutomaticRestartTime` (7-day limit). Pre-flight warns.
- **Managed by CloudFormation** (`aws:cloudformation:stack-name` ev-uat-eks, logical id UatRDSInstance): a restored
  instance is **outside the stack** → IaC adoption (§3) or the stack keeps pointing at the old instance; never let a stack
  update "fix" the drift by replacing resources during the event.
- **No read replica** (`ReadReplicaDBInstanceIdentifiers: []`): S2 (promote replica) is not available in UAT today →
  RB-UAT-S2 needs the replica first; until then S3/S4 are the UAT scenarios.
- Subnets: 3 subnets but only **2 AZs** (1a, 1b, 1b) → Multi-AZ possible; no third AZ.

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
