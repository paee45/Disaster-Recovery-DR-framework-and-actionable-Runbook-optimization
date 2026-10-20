#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT

printf '%s\n' \
  'export TF_VAR_account_id=000000000000' \
  'export TF_VAR_aws_profile=lab_sandbox' \
  'export TF_VAR_region=ap-southeast-1' \
  'export BB3_SNAPSHOT_ID=snapshot-no-replica' \
  'export BB3_RESTORE_TARGET_PRIMARY_ID=restore-primary' \
  'export BB3_RESTORE_TARGET_REPLICA_ID=replica-target' > "$TEMP/sandbox.env"
BASELINE_STORE="$TEMP/baselines"
CAPTURE_NAME=20261020T000000Z-test
mkdir -p "$BASELINE_STORE/$CAPTURE_NAME/primary"
jq -n '{source:"primary-no-replica",account:"000000000000",region:"ap-southeast-1",
  tags:[{Key:"env",Value:"uat"},{Key:"app",Value:"bb3"},{Key:"Role",Value:"primary"}],
  instance:{DBInstanceIdentifier:"primary-no-replica",DBInstanceArn:"arn:aws:rds:ap-southeast-1:000000000000:db:primary-no-replica",
    DBInstanceStatus:"available",ReadReplicaDBInstanceIdentifiers:[],
    DBParameterGroups:[{DBParameterGroupName:"pg-original",ParameterApplyStatus:"in-sync"}],
    DBSubnetGroup:{DBSubnetGroupName:"subnets-original",VpcId:"vpc-original"},
    VpcSecurityGroups:[{VpcSecurityGroupId:"sg-original"}],DBInstanceClass:"db.t4g.micro",
    AvailabilityZone:"ap-southeast-1a",PubliclyAccessible:false,MultiAZ:false,BackupRetentionPeriod:7,
    PreferredBackupWindow:"18:00-18:30",PreferredMaintenanceWindow:"sun:19:00-sun:19:30",
    Endpoint:{Port:5432},Engine:"postgres",EngineVersion:"17.9",AllocatedStorage:20,StorageEncrypted:false,
    DBName:"app",MasterUsername:"sandbox_admin",DeletionProtection:false,CopyTagsToSnapshot:true,
    AutoMinorVersionUpgrade:true,IAMDatabaseAuthenticationEnabled:false,NetworkType:"IPV4",EnabledCloudwatchLogsExports:[]}}' \
  > "$BASELINE_STORE/$CAPTURE_NAME/primary/baseline.json"
baseline_hash="$(shasum -a 256 "$BASELINE_STORE/$CAPTURE_NAME/primary/baseline.json" | awk '{print $1}')"
printf '{"schemaVersion":1,"status":"complete","profile":"lab_sandbox","region":"ap-southeast-1","directory":"%s","primary":"primary/baseline.json","replica":null}\n' \
  "$CAPTURE_NAME" > "$BASELINE_STORE/latest.json"
printf '{"files":[{"path":"primary/baseline.json","sha256":"%s"}]}\n' "$baseline_hash" \
  > "$BASELINE_STORE/$CAPTURE_NAME/manifest.json"

git() { return 0; }
aws() {
  [[ "$1" == --profile && "$2" == lab_sandbox && "$3" == --region && "$4" == ap-southeast-1 && "$5" == --no-cli-pager ]] || return 97
  shift 5
  printf '%s\n' "$*" >> "$TEST_CALLS"
  case "$1 $2" in
    'sts get-caller-identity') printf '%s\n' '000000000000' ;;
    'rds describe-db-snapshots')
      printf '%s\n' '{"DBSnapshots":[{"DBSnapshotIdentifier":"snapshot-no-replica","DBSnapshotArn":"arn:aws:rds:ap-southeast-1:000000000000:snapshot:snapshot-no-replica","DBInstanceIdentifier":"primary-no-replica","Status":"available","Engine":"postgres","EngineVersion":"17.8","Port":5432,"AllocatedStorage":20,"Encrypted":false,"VpcId":"vpc-original","AvailabilityZone":"ap-southeast-1a"}]}' ;;
    'rds describe-db-instances')
      local instance='{"DBInstanceIdentifier":"primary-no-replica","DBInstanceArn":"arn:aws:rds:ap-southeast-1:000000000000:db:primary-no-replica","DBInstanceStatus":"available","ReadReplicaDBInstanceIdentifiers":[],"DBParameterGroups":[{"DBParameterGroupName":"pg-original","ParameterApplyStatus":"in-sync"}],"DBSubnetGroup":{"DBSubnetGroupName":"subnets-original","VpcId":"vpc-original"},"VpcSecurityGroups":[{"VpcSecurityGroupId":"sg-original"}],"DBInstanceClass":"db.t4g.micro","AvailabilityZone":"ap-southeast-1a","PubliclyAccessible":false,"MultiAZ":false,"BackupRetentionPeriod":7,"PreferredBackupWindow":"18:00-18:30","PreferredMaintenanceWindow":"sun:19:00-sun:19:30","Endpoint":{"Port":5432},"Engine":"postgres","EngineVersion":"17.9","AllocatedStorage":20,"StorageEncrypted":false,"DBName":"app","MasterUsername":"sandbox_admin","DeletionProtection":false,"CopyTagsToSnapshot":true,"AutoMinorVersionUpgrade":true,"IAMDatabaseAuthenticationEnabled":false,"NetworkType":"IPV4","EnabledCloudwatchLogsExports":[]}'
      if [[ "$*" == *'--query DBInstances[0]'* ]]; then printf '%s\n' "$instance"; else printf '{"DBInstances":[%s]}\n' "$instance"; fi ;;
    'rds describe-db-parameter-groups') printf '%s\n' 'postgres17' ;;
    'rds describe-db-parameters') printf '%s\n' '[]' ;;
    'rds describe-db-subnet-groups') printf '%s\n' '["ap-southeast-1a","ap-southeast-1b"]' ;;
    'rds list-tags-for-resource') printf '%s\n' '[{"Key":"env","Value":"dev"},{"Key":"app","Value":"bb3"}]' ;;
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
export BB3_RESTORE_CONFIG="$TEMP/sandbox.env" BB3_RESTORE_BASELINE_DIR="$BASELINE_STORE" TEST_CALLS="$TEMP/calls"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

bash "$HERE/restore-drill.sh" preview snapshot-no-replica restore-primary replica-target > "$TEMP/preview.txt" 2>&1
grep -F 'Original replica: not present in source baseline.' "$TEMP/preview.txt" >/dev/null
grep -F 'New replica request uses the primary baseline' "$TEMP/preview.txt" >/dev/null
grep -F 'PreferredMaintenanceWindow' "$TEMP/preview.txt" >/dev/null
grep -F 'Snapshot vs captured primary baseline (differences only)' "$TEMP/preview.txt" >/dev/null
grep -F 'EngineVersion' "$TEMP/preview.txt" >/dev/null
grep -F 'Tag:env' "$TEMP/preview.txt" >/dev/null
grep -F 'uat' "$TEMP/preview.txt" >/dev/null
grep -F 'dev' "$TEMP/preview.txt" >/dev/null
replica_table="$(sed -n '/Replica create request (populated fields only)/,/Expected inherited parameter group/p' "$TEMP/preview.txt")"
[[ "$replica_table" == *'MATCH'* ]]
[[ "$replica_table" == *'EXPECTED: NEW RESTORE PRIMARY'* ]]
[[ "$replica_table" != *'DBSubnetGroupName'* && "$replica_table" != *'DBParameterGroupName'* ]]
if grep -F 'rds restore-db-instance-from-db-snapshot --cli-input-json' "$TEMP/calls" >/dev/null \
  || grep -F 'rds create-db-instance-read-replica --cli-input-json' "$TEMP/calls" >/dev/null; then
  echo 'FAIL preview submitted a mutating RDS request' >&2
  exit 1
fi
echo 'PASS source without replica is detected; preview is read-only and prepares a separate replica step'
if bash "$HERE/restore-drill.sh" restore > "$TEMP/diff-gate.txt" 2>&1; then
  echo 'FAIL restore proceeded with a snapshot difference and no interactive acceptance' >&2
  exit 1
fi
grep -F 'Snapshot differences require explicit interactive acceptance.' "$TEMP/diff-gate.txt" >/dev/null
if grep -F 'rds restore-db-instance-from-db-snapshot --cli-input-json' "$TEMP/calls" >/dev/null; then
  echo 'FAIL diff gate allowed a restore API request' >&2
  exit 1
fi
echo 'PASS snapshot/baseline difference is shown and blocks restore without explicit acceptance'
bash "$HERE/restore-drill.sh" preview > "$TEMP/default-preview.txt" 2>&1
grep -F 'Snapshot: snapshot-no-replica (source primary: primary-no-replica)' "$TEMP/default-preview.txt" >/dev/null
grep -F 'Primary restore request (populated fields only)' "$TEMP/default-preview.txt" >/dev/null
echo 'PASS preview loads snapshot and restore targets from sandbox.env without repeated IDs'
bash "$HERE/restore-drill.sh" status > "$TEMP/status.txt" 2>&1
grep -F 'primary target: available' "$TEMP/status.txt" >/dev/null
grep -F 'replica target: available' "$TEMP/status.txt" >/dev/null
echo 'PASS read-only status checks both saved targets without requiring copied IDs'