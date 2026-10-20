#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
CONFIG="$TEMP/sandbox.env"
SCRIPT="$HERE/discover-env.sh"
printf '%s\n' \
  'export TF_VAR_aws_profile=pa_iam_aws_sandbox' \
  'export TF_VAR_region=ap-southeast-1' \
  'export TF_VAR_account_id=000000000000' > "$CONFIG"

git() { return 0; }
aws() {
  [[ "$1" == --profile && "$2" == pa_iam_aws_sandbox && "$3" == --region && "$4" == ap-southeast-1 && "$5" == --no-cli-pager ]] || return 97
  shift 5
  case "$1 $2" in
    'sts get-caller-identity') printf '%s\n' 000000000000 ;;
    'rds describe-db-instances')
      if [[ "$3" == --db-instance-identifier ]]; then
        case "$4" in
          primary-without-name-prefix)
            printf '%s\n' '{"DBInstanceIdentifier":"primary-without-name-prefix","DBInstanceStatus":"available","ReadReplicaDBInstanceIdentifiers":["attached-replica"]}' ;;
          attached-replica)
            printf '%s\n' '{"DBInstanceIdentifier":"attached-replica","DBInstanceStatus":"available","ReadReplicaSourceDBInstanceIdentifier":"primary-without-name-prefix"}' ;;
          *) return 98 ;;
        esac
      else
        if [[ "${TEST_TARGET_EXISTS:-}" == true ]]; then
          printf '%s\n' '{"DBInstances":[{"DBInstanceIdentifier":"primary-without-name-prefix","DBInstanceArn":"arn:aws:rds:ap-southeast-1:000000000000:db:primary-without-name-prefix","Engine":"postgres","DBInstanceStatus":"available"},{"DBInstanceIdentifier":"attached-replica","DBInstanceArn":"arn:aws:rds:ap-southeast-1:000000000000:db:attached-replica","Engine":"postgres","DBInstanceStatus":"available","ReadReplicaSourceDBInstanceIdentifier":"primary-without-name-prefix"},{"DBInstanceIdentifier":"unrelated-uat","DBInstanceArn":"arn:aws:rds:ap-southeast-1:000000000000:db:unrelated-uat","Engine":"postgres","DBInstanceStatus":"available"},{"DBInstanceIdentifier":"occupied-restore-target","Engine":"mysql","DBInstanceStatus":"available"}]}'
        else
          printf '%s\n' '{"DBInstances":[{"DBInstanceIdentifier":"primary-without-name-prefix","DBInstanceArn":"arn:aws:rds:ap-southeast-1:000000000000:db:primary-without-name-prefix","Engine":"postgres","DBInstanceStatus":"available"},{"DBInstanceIdentifier":"attached-replica","DBInstanceArn":"arn:aws:rds:ap-southeast-1:000000000000:db:attached-replica","Engine":"postgres","DBInstanceStatus":"available","ReadReplicaSourceDBInstanceIdentifier":"primary-without-name-prefix"},{"DBInstanceIdentifier":"unrelated-uat","DBInstanceArn":"arn:aws:rds:ap-southeast-1:000000000000:db:unrelated-uat","Engine":"postgres","DBInstanceStatus":"available"}]}'
        fi
      fi
      ;;
    'rds list-tags-for-resource')
      case "$4" in
        *primary-without-name-prefix)
          if [[ "${TEST_NO_MATCH:-}" == true ]]; then
            printf '%s\n' '[{"Key":"app","Value":"bb3"},{"Key":"env","Value":"dev"}]'
          else
            printf '%s\n' '[{"Key":"app","Value":"bb3"},{"Key":"env","Value":"uat"}]'
          fi ;;
        *attached-replica)
          printf '%s\n' '[{"Key":"app","Value":"bb3"},{"Key":"env","Value":"uat"}]' ;;
        *unrelated-uat)
          printf '%s\n' '[{"Key":"dr-env","Value":"uat"},{"Key":"Role","Value":"primary"}]' ;;
        *) return 98 ;;
      esac
      ;;
    'rds describe-db-snapshots')
      if [[ "$*" == *--db-snapshot-identifier* && "$*" == *--query* ]]; then
        printf '%s\n' '2026-10-19T18:11:12.993000+00:00'
      elif [[ "$*" == *--db-snapshot-identifier* ]]; then
        printf '%s\n' '{"DBSnapshots":[{"DBSnapshotIdentifier":"bb3-snapshot","Status":"available","DBInstanceIdentifier":"primary-without-name-prefix","SnapshotCreateTime":"2026-10-19T18:11:12.993000+00:00"}]}'
      else
        printf '%s\n' '{"DBSnapshots":[{"DBSnapshotIdentifier":"older-snapshot","Status":"available","DBInstanceIdentifier":"primary-without-name-prefix","SnapshotCreateTime":"2026-10-18T18:11:12.993000+00:00"},{"DBSnapshotIdentifier":"latest-snapshot","Status":"available","DBInstanceIdentifier":"primary-without-name-prefix","SnapshotCreateTime":"2026-10-19T18:11:12.993000+00:00"}]}'
      fi
      ;;
    *) echo 'Unexpected AWS action' >&2; return 98 ;;
  esac
}
export -f git aws
export BB3_SANDBOX_CONFIG="$CONFIG" BB3_DRILL_ENV_FILE="$CONFIG"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

output="$(bash "$SCRIPT" uat --print)"
[[ "$output" == *'export ENV=uat'* ]]
[[ "$output" == *'export APP=bb3'* ]]
[[ "$output" == *'BB3_SOURCE_PRIMARY_ID=primary-without-name-prefix'* ]]
[[ "$output" == *'BB3_SOURCE_REPLICA_ID=attached-replica'* ]]
[[ "$output" == *'BB3_SNAPSHOT_ID=latest-snapshot'* ]]
[[ "$output" == *'older-snapshot'* && "$output" == *'latest daily backup; default'* ]]
target_suffix="$(printf '%s' latest-snapshot | shasum -a 256 | cut -c1-12)"
[[ "$output" == *"BB3_RESTORE_TARGET_PRIMARY_ID=bb3-uat-restore-$target_suffix"* ]]
[[ "$output" != *unrelated-uat* ]]
echo 'PASS discovery uses exact env/app tags and selects the newest available snapshot by default'

output="$(TEST_NO_MATCH=true bash "$SCRIPT" uat --primary primary-without-name-prefix --replica attached-replica --snapshot bb3-snapshot --print)"
[[ "$output" == *'no available RDS primary matched env=uat and app=bb3'* ]]
[[ "$output" == *$'\033[31m'* ]]
[[ "$output" == *'unrelated-uat [primary candidate]'* ]]
[[ "$output" == *'attached-replica [replica, not selectable as primary]'* ]]
echo 'PASS tag-mismatch fallback warns and shows all PostgreSQL RDS entries in red'

printf '%s\n' \
  'export TF_VAR_aws_profile=pa_iam_aws_sandbox' \
  'export TF_VAR_region=ap-southeast-1' \
  'export TF_VAR_account_id=000000000000' \
  'export ENV=uat' \
  'export APP=bb3' \
  'export BB3_AWS_PROFILE=pa_iam_aws_sandbox' \
  'export BB3_AWS_REGION=ap-southeast-1' \
  'export BB3_ACCOUNT_ID=000000000000' \
  'export BB3_SOURCE_PRIMARY_ID=primary-without-name-prefix' \
  'export BB3_SOURCE_REPLICA_ID=attached-replica' \
  'export BB3_SNAPSHOT_ID=bb3-snapshot' \
  'export BB3_SNAPSHOT_TIME=2026-10-19T18:11:12.993000+00:00' \
  "export BB3_RESTORE_TARGET_PRIMARY_ID=bb3-uat-restore-$(printf '%s' bb3-snapshot | shasum -a 256 | cut -c1-12)" \
  "export BB3_RESTORE_TARGET_REPLICA_ID=bb3-uat-replica-$(printf '%s' bb3-snapshot | shasum -a 256 | cut -c1-12)" > "$CONFIG"
output="$(bash "$SCRIPT" uat --primary primary-without-name-prefix --replica attached-replica --snapshot bb3-snapshot)"
[[ "$output" == *'Saved BB3 discovery selections already match; no changes needed.'* ]]
[[ "$output" == *"File: $CONFIG"* ]]
[[ "$output" != *'Write these selections'* ]]
echo 'PASS unchanged selections do not prompt or rewrite sandbox.env'

printf '%s\n' \
  'export TF_VAR_aws_profile=pa_iam_aws_sandbox' \
  'export TF_VAR_region=ap-southeast-1' \
  'export TF_VAR_account_id=000000000000' \
  'export ENV=uat' \
  'export APP=bb3' \
  'export BB3_AWS_PROFILE=pa_iam_aws_sandbox' \
  'export BB3_AWS_REGION=ap-southeast-1' \
  'export BB3_ACCOUNT_ID=000000000000' \
  'export BB3_SOURCE_PRIMARY_ID=primary-without-name-prefix' \
  'export BB3_SOURCE_REPLICA_ID=attached-replica' \
  'export BB3_SNAPSHOT_ID=latest-snapshot' \
  'export BB3_SNAPSHOT_TIME=2026-10-19T18:11:12.993000+00:00' \
  'export BB3_RESTORE_TARGET_PRIMARY_ID=occupied-restore-target' \
  'export BB3_RESTORE_TARGET_REPLICA_ID=occupied-replica-target' > "$CONFIG"
output="$(TEST_TARGET_EXISTS=true bash "$SCRIPT" uat --primary primary-without-name-prefix --replica attached-replica --print)"
[[ "$output" != *'BB3_RESTORE_TARGET_PRIMARY_ID=occupied-restore-target'* ]]
[[ "$output" == *'BB3_RESTORE_TARGET_PRIMARY_ID=bb3-uat-restore-'* ]]
echo 'PASS discovery rotates saved restore targets when AWS reports an occupied target ID'