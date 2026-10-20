#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT

printf '%s\n' \
  'export TF_VAR_account_id=000000000000' \
  'export TF_VAR_aws_profile=lab_sandbox' \
  'export TF_VAR_region=ap-southeast-1' > "$TEMP/sandbox.env"

git() { return 0; }
aws() {
  [[ "$1" == --profile && "$2" == lab_sandbox && "$3" == --region && "$4" == ap-southeast-1 && "$5" == --no-cli-pager ]] || return 97
  shift 5
  printf '%s\n' "$*" >> "$TEST_CALLS"
  case "$1 $2" in
    'sts get-caller-identity') printf '%s\n' '000000000000' ;;
    'rds describe-db-snapshots')
      printf '%s\n' '{"DBSnapshots":[{"DBSnapshotIdentifier":"snapshot-no-replica","DBInstanceIdentifier":"primary-no-replica","Status":"available"}]}' ;;
    'rds describe-db-instances')
      local instance='{"DBInstanceIdentifier":"primary-no-replica","DBInstanceArn":"arn:aws:rds:ap-southeast-1:000000000000:db:primary-no-replica","DBInstanceStatus":"available","ReadReplicaDBInstanceIdentifiers":[],"DBParameterGroups":[{"DBParameterGroupName":"pg-original","ParameterApplyStatus":"in-sync"}],"DBSubnetGroup":{"DBSubnetGroupName":"subnets-original"},"VpcSecurityGroups":[{"VpcSecurityGroupId":"sg-original"}],"DBInstanceClass":"db.t4g.micro","AvailabilityZone":"ap-southeast-1a","PubliclyAccessible":false,"MultiAZ":false,"BackupRetentionPeriod":7,"PreferredBackupWindow":"18:00-18:30","Endpoint":{"Port":5432},"Engine":"postgres","EngineVersion":"17.9","DBName":"app","MasterUsername":"sandbox_admin","DeletionProtection":false,"CopyTagsToSnapshot":true,"AutoMinorVersionUpgrade":true,"IAMDatabaseAuthenticationEnabled":false,"NetworkType":"IPV4","EnabledCloudwatchLogsExports":[]}'
      if [[ "$*" == *'--query DBInstances[0]'* ]]; then printf '%s\n' "$instance"; else printf '{"DBInstances":[%s]}\n' "$instance"; fi ;;
    'rds describe-db-parameter-groups') printf '%s\n' 'postgres17' ;;
    'rds describe-db-parameters') printf '%s\n' '[]' ;;
    'rds describe-db-subnet-groups') printf '%s\n' '["ap-southeast-1a","ap-southeast-1b"]' ;;
    'rds list-tags-for-resource') printf '%s\n' '[]' ;;
    'rds restore-db-instance-from-db-snapshot')
      [[ "$*" == *'--generate-cli-skeleton input'* ]] || return 98
      jq -nc '{DBInstanceIdentifier:"",DBSnapshotIdentifier:"",DBInstanceClass:"",AvailabilityZone:"",DBParameterGroupName:"",DBSubnetGroupName:"",VpcSecurityGroupIds:[],PubliclyAccessible:false,BackupRetentionPeriod:0,PreferredBackupWindow:"",Port:0,MultiAZ:false,DeletionProtection:false,StorageType:"",NetworkType:"",CopyTagsToSnapshot:false,CACertificateIdentifier:"",AutoMinorVersionUpgrade:false,EnableIAMDatabaseAuthentication:false,EnableCloudwatchLogsExports:[],Tags:[]}' ;;
    'rds create-db-instance-read-replica')
      [[ "$*" == *'--generate-cli-skeleton input'* ]] || return 98
      jq -nc '{DBInstanceIdentifier:"",SourceDBInstanceIdentifier:"",DBInstanceClass:"",AvailabilityZone:"",VpcSecurityGroupIds:[],PubliclyAccessible:false,DeletionProtection:false,CopyTagsToSnapshot:false,AutoMinorVersionUpgrade:false,EnableIAMDatabaseAuthentication:false,NetworkType:"",Port:0,EnableCloudwatchLogsExports:[],Tags:[]}' ;;
    *) echo "Unexpected AWS call: $*" >&2; return 98 ;;
  esac
}
export -f git aws
export BB3_RESTORE_CONFIG="$TEMP/sandbox.env" TEST_CALLS="$TEMP/calls"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

bash "$HERE/restore-drill.sh" preview snapshot-no-replica restore-primary replica-target > "$TEMP/preview.txt" 2>&1
grep -F 'Original replica: not present in source baseline.' "$TEMP/preview.txt" >/dev/null
grep -F 'New replica request uses the primary baseline' "$TEMP/preview.txt" >/dev/null
grep -F 'PreferredMaintenanceWindow' "$TEMP/preview.txt" >/dev/null
replica_table="$(sed -n '/Replica create request (populated fields only)/,/Expected inherited parameter group/p' "$TEMP/preview.txt")"
[[ "$replica_table" == *'MATCH'* ]]
[[ "$replica_table" != *'DBSubnetGroupName'* && "$replica_table" != *'DBParameterGroupName'* ]]
if grep -F 'rds restore-db-instance-from-db-snapshot --cli-input-json' "$TEMP/calls" >/dev/null \
  || grep -F 'rds create-db-instance-read-replica --cli-input-json' "$TEMP/calls" >/dev/null; then
  echo 'FAIL preview submitted a mutating RDS request' >&2
  exit 1
fi
echo 'PASS source without replica is detected; preview is read-only and prepares a separate replica step'