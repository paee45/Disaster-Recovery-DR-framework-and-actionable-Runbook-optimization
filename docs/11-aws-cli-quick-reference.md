# 11 — AWS CLI & kubectl Quick Reference for DR (TICKET-108)

Only the commands the runbooks use. Always `source env/<env>.env` first; the variables below come from there.
Prefer the **scripts**, which wrap these commands safely; use the raw commands to understand them or for troubleshooting.

## Session setup
```bash
source env/uat.env
export AWS_DEFAULT_REGION=$AWS_REGION                 # avoid region mistakes
aws --profile $AWS_PROFILE --region $AWS_REGION sts get-caller-identity                            # right account/role?
aws --profile $AWS_PROFILE --region $AWS_REGION eks update-kubeconfig --name <cluster> --alias "$EKS_CONTEXT"   # once per machine
./automation/scripts/dr-env-check.sh S3                # validates everything above
```

## RDS — inspect
```bash
aws --profile $AWS_PROFILE --region $AWS_REGION rds describe-db-instances --db-instance-identifier "$PRIMARY_DB" \
  --query 'DBInstances[0].{status:DBInstanceStatus,az:AvailabilityZone,multiAZ:MultiAZ,endpoint:Endpoint.Address,sgs:VpcSecurityGroups[].VpcSecurityGroupId,retention:BackupRetentionPeriod}'
aws --profile $AWS_PROFILE --region $AWS_REGION rds describe-events --source-type db-instance --source-identifier "$PRIMARY_DB" --duration 120     # last 2 h
aws --profile $AWS_PROFILE --region $AWS_REGION rds describe-db-snapshots --db-instance-identifier "$PRIMARY_DB" --snapshot-type automated \
  --query 'reverse(sort_by(DBSnapshots,&SnapshotCreateTime))[:3].[DBSnapshotIdentifier,SnapshotCreateTime]' --output table
aws --profile $AWS_PROFILE --region $AWS_REGION rds describe-db-instance-automated-backups --db-instance-identifier "$PRIMARY_DB" --query 'DBInstanceAutomatedBackups[0].RestoreWindow'
```

## RDS — act (script equivalents in brackets)
```bash
# baseline of the source      [dr-restore.sh capture <src>]  → evidence/baselines/<env>/baseline-<src>.json (schedule it daily)
# preview the restore request [dr-restore.sh plan snapshot <snap> <new>]
# restore snapshot            [dr-restore.sh snapshot <snap> <new>]  = aws --profile $AWS_PROFILE --region $AWS_REGION rds restore-db-instance-from-db-snapshot --cli-input-json file://restore-request-<new>.json
# point-in-time restore       [dr-restore.sh pitr <src> <new> <ISO8601|latest>]
aws --profile $AWS_PROFILE --region $AWS_REGION rds wait db-instance-available --db-instance-identifier <new>          # [dr-restore.sh wait <new>] (shows progress)
aws --profile $AWS_PROFILE --region $AWS_REGION rds modify-db-instance --db-instance-identifier <new> --backup-retention-period 7 --apply-immediately   # [dr-restore.sh harden] (CLI default retention = 1 day!)
# compare every setting with the baseline   [dr-restore.sh validate <new>] · pg_settings [dr-restore.sh validate-pg]
aws --profile $AWS_PROFILE --region $AWS_REGION rds modify-db-instance --db-instance-identifier <db> --vpc-security-group-ids sg-1 sg-2 sg-3 --apply-immediately  # ALL SGs, space-separated
aws --profile $AWS_PROFILE --region $AWS_REGION rds promote-read-replica --db-instance-identifier "$REPLICA_DB" --backup-retention-period 7          # S2 ⚠ irreversible
aws --profile $AWS_PROFILE --region $AWS_REGION rds reboot-db-instance --db-instance-identifier "$PRIMARY_DB" --force-failover                      # S1 test / FB-S1 ⚠ outage
aws --profile $AWS_PROFILE --region $AWS_REGION rds start-db-instance --db-instance-identifier <db>
aws --profile $AWS_PROFILE --region $AWS_REGION rds delete-db-instance --db-instance-identifier <db> --skip-final-snapshot                         # exercise clean-up only
```
Common pitfalls: lists are **space-separated** (no commas, no JSON); quote variables (`"$VAR"`); `--apply-immediately` is
needed for changes to take effect now; you cannot `stop-db-instance` an instance that has a read replica.

## Secrets Manager
```bash
aws --profile $AWS_PROFILE --region $AWS_REGION secretsmanager describe-secret --secret-id "$SECRET_ID" --query '{rotation:RotationEnabled,stages:VersionIdsToStages}'
aws --profile $AWS_PROFILE --region $AWS_REGION secretsmanager get-secret-value --secret-id "$SECRET_ID" --query SecretString --output text | jq '{host,port,dbname,username}'   # never print the password
# update host   [dr-secret-cutover.sh apply]   ·   roll back   [dr-secret-cutover.sh rollback]
aws --profile $AWS_PROFILE --region $AWS_REGION secretsmanager cancel-rotate-secret --secret-id "$SECRET_ID"           # suspend rotation during DR
```

## Kubernetes (EKS)
```bash
K="kubectl --context $EKS_CONTEXT -n $K8S_NS"
$K get externalsecret "$K8S_SECRET" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
$K annotate externalsecret "$K8S_SECRET" force-sync="$(date +%s)" --overwrite   # sync now
$K get secret "$K8S_SECRET" -o jsonpath="{.data.$K8S_HOST_KEY}" | base64 -d; echo
./automation/scripts/dr-eks-rollout.sh inventory        # who uses the secret, annotated or not
./automation/scripts/k8s-secret-consumers.sh --context $EKS_CONTEXT -n $K8S_NS -s $K8S_SECRET check     # STALE = still on the old secret
./automation/scripts/k8s-secret-consumers.sh --context $EKS_CONTEXT -n $K8S_NS -s $K8S_SECRET restart   # restart only the STALE ones
$K rollout restart deploy/<name> && $K rollout status deploy/<name> --timeout=300s
$K get pods -o wide --sort-by=.status.startTime
```

## psql
```bash
psql "$TARGET_DSN" -c "select now(), pg_is_in_recovery(), current_setting('default_transaction_read_only')"
psql "$TARGET_DSN" -f automation/sql/20-postfailover-verify.sql
```

## Timeline helpers (dr-lib.sh)
```bash
dr_mark T0 --at 2026-08-04T08:30:00Z   # back-fill (UTC!)
dr_phase start restore 12 ; …  ; dr_phase end restore 12
dr_summary                               # per-phase times + elapsed since T0 vs the 30 min target
```
