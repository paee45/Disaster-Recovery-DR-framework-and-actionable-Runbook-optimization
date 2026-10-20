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
jq -n '{Parameters:[{ParameterName:"max_connections",ParameterValue:"100",Source:"user"}]}' \
  > "$BASELINE_STORE/$CAPTURE_NAME/primary/parameters-1.json"
parameter_hash="$(shasum -a 256 "$BASELINE_STORE/$CAPTURE_NAME/primary/parameters-1.json" | awk '{print $1}')"
jq -n --arg directory "$CAPTURE_NAME" \
  '{schemaVersion:1,status:"complete",capturedAt:"2026-10-20T00:00:00Z",profile:"lab_sandbox",
    region:"ap-southeast-1",directory:$directory,primary:"primary/baseline.json",replica:null,
    parameters:"Each role contains full paginated AWS parameter definitions and values, not SQL pg_settings"}' \
  > "$BASELINE_STORE/$CAPTURE_NAME/capture.json"
capture_hash="$(shasum -a 256 "$BASELINE_STORE/$CAPTURE_NAME/capture.json" | awk '{print $1}')"
cp "$BASELINE_STORE/$CAPTURE_NAME/capture.json" "$BASELINE_STORE/latest.json"
printf '{"files":[{"path":"capture.json","sha256":"%s"},{"path":"primary/baseline.json","sha256":"%s"},{"path":"primary/parameters-1.json","sha256":"%s"}]}\n' \
  "$capture_hash" "$baseline_hash" "$parameter_hash" > "$BASELINE_STORE/$CAPTURE_NAME/manifest.json"

git() { return 0; }
aws() {
  [[ "$1" == --profile && "$2" == lab_sandbox && "$3" == --region && "$4" == ap-southeast-1 && "$5" == --no-cli-pager ]] || return 97
  shift 5
  printf '%s\n' "$*" >> "$TEST_CALLS"
  case "$1 $2" in
    'sts get-caller-identity') printf '%s\n' '000000000000' ;;
    'rds describe-db-snapshots')
      snapshot_version=17.8; [[ "${TEST_NO_SNAPSHOT_DIFF:-}" != true ]] || snapshot_version=17.9
      snapshot_vpc=vpc-different; [[ "${TEST_NO_SNAPSHOT_DIFF:-}" != true ]] || snapshot_vpc=vpc-original
      printf '{"DBSnapshots":[{"DBSnapshotIdentifier":"snapshot-no-replica","DBSnapshotArn":"arn:aws:rds:ap-southeast-1:000000000000:snapshot:snapshot-no-replica","DBInstanceIdentifier":"primary-no-replica","Status":"available","Engine":"postgres","EngineVersion":"%s","Port":5432,"AllocatedStorage":20,"Encrypted":false,"VpcId":"%s","AvailabilityZone":"ap-southeast-1a"}]}\n' "$snapshot_version" "$snapshot_vpc" ;;
    'rds describe-db-instances')
      local instance='{"DBInstanceIdentifier":"primary-no-replica","DBInstanceArn":"arn:aws:rds:ap-southeast-1:000000000000:db:primary-no-replica","DBInstanceStatus":"available","ReadReplicaDBInstanceIdentifiers":[],"DBParameterGroups":[{"DBParameterGroupName":"pg-original","ParameterApplyStatus":"in-sync"}],"DBSubnetGroup":{"DBSubnetGroupName":"subnets-original","VpcId":"vpc-original"},"VpcSecurityGroups":[{"VpcSecurityGroupId":"sg-original"}],"DBInstanceClass":"db.t4g.micro","AvailabilityZone":"ap-southeast-1a","PubliclyAccessible":false,"MultiAZ":false,"BackupRetentionPeriod":7,"PreferredBackupWindow":"18:00-18:30","PreferredMaintenanceWindow":"sun:19:00-sun:19:30","Endpoint":{"Port":5432},"Engine":"postgres","EngineVersion":"17.9","AllocatedStorage":20,"StorageEncrypted":false,"DBName":"app","MasterUsername":"sandbox_admin","DeletionProtection":false,"CopyTagsToSnapshot":true,"AutoMinorVersionUpgrade":true,"IAMDatabaseAuthenticationEnabled":false,"NetworkType":"IPV4","EnabledCloudwatchLogsExports":[]}'
      if [[ "$*" == *'--db-instance-identifier replica-target'* ]]; then
        instance='{"DBInstanceIdentifier":"replica-target","DBInstanceArn":"arn:aws:rds:ap-southeast-1:000000000000:db:replica-target","ReadReplicaSourceDBInstanceIdentifier":"restore-primary","DBInstanceStatus":"available","DBParameterGroups":[{"DBParameterGroupName":"pg-original","ParameterApplyStatus":"in-sync"}],"DBSubnetGroup":{"DBSubnetGroupName":"subnets-original","VpcId":"vpc-original"},"VpcSecurityGroups":[{"VpcSecurityGroupId":"sg-original"}],"DBInstanceClass":"db.t4g.micro","AvailabilityZone":"ap-southeast-1b","PubliclyAccessible":false,"BackupRetentionPeriod":0,"PreferredMaintenanceWindow":"sun:19:00-sun:19:30","Endpoint":{"Port":5432},"Engine":"postgres","EngineVersion":"17.9","AllocatedStorage":20,"StorageEncrypted":false,"DeletionProtection":false,"CopyTagsToSnapshot":true,"AutoMinorVersionUpgrade":true,"IAMDatabaseAuthenticationEnabled":false,"NetworkType":"IPV4","EnabledCloudwatchLogsExports":[]}'
      elif [[ "$*" == *'--db-instance-identifier restore-primary'* ]]; then
        instance="${instance/primary-no-replica/restore-primary}"
      fi
      if [[ "$*" == *'--query DBInstances[0]'* ]]; then printf '%s\n' "$instance"; else printf '{"DBInstances":[%s]}\n' "$instance"; fi ;;
    'rds describe-db-parameter-groups') printf '%s\n' 'postgres17' ;;
    'rds describe-db-parameters')
      if [[ "$*" == *'--source user'* ]]; then
        printf '%s\n' '[]'
      else
        printf '%s\n' '{"Parameters":[{"ParameterName":"max_connections","ParameterValue":"200","Source":"user"}]}'
      fi ;;
    'rds describe-db-subnet-groups') printf '%s\n' '["ap-southeast-1a","ap-southeast-1b"]' ;;
    'rds list-tags-for-resource')
      if [[ "${TEST_NO_SNAPSHOT_DIFF:-}" == true ]]; then
        printf '%s\n' '[{"Key":"env","Value":"uat"},{"Key":"app","Value":"bb3"},{"Key":"Role","Value":"primary"}]'
      else
        printf '%s\n' '[{"Key":"env","Value":"dev"},{"Key":"app","Value":"bb3-sandbox"}]'
      fi ;;
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
grep -F 'Diff type' "$TEMP/preview.txt" >/dev/null
grep -F 'EngineVersion' "$TEMP/preview.txt" >/dev/null
grep -F 'NETWORK' "$TEMP/preview.txt" >/dev/null
grep -F 'VpcId' "$TEMP/preview.txt" >/dev/null
grep -F 'Snapshot tag differences (one choice at a time; option 1 is the default)' "$TEMP/preview.txt" >/dev/null
grep -F 'Snapshot tag decisions (Name/Role are assigned to the new target automatically)' "$TEMP/preview.txt" >/dev/null
grep -F 'Captured primary [1]' "$TEMP/preview.txt" >/dev/null
grep -F 'Selected snapshot [2]' "$TEMP/preview.txt" >/dev/null
grep -F 'uat (default)' "$TEMP/preview.txt" >/dev/null
grep -F 'bb3 (default)' "$TEMP/preview.txt" >/dev/null
grep -F 'bb3-sandbox' "$TEMP/preview.txt" >/dev/null
grep -F 'app' "$TEMP/preview.txt" >/dev/null
grep -F 'bb3 (default)' "$TEMP/preview.txt" >/dev/null
grep -F 'bb3-sandbox' "$TEMP/preview.txt" >/dev/null
grep -F 'primary parameters: 1 captured / 1 live API records; review differences.' "$TEMP/preview.txt" >/dev/null
grep -F 'max_connections' "$TEMP/preview.txt" >/dev/null
grep -F '100 [user]' "$TEMP/preview.txt" >/dev/null
grep -F '200 [user]' "$TEMP/preview.txt" >/dev/null
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
grep -F 'Snapshot tag differences require interactive per-tag choices.' "$TEMP/diff-gate.txt" >/dev/null
if grep -F 'rds restore-db-instance-from-db-snapshot --cli-input-json' "$TEMP/calls" >/dev/null; then
  echo 'FAIL diff gate allowed a restore API request' >&2
  exit 1
fi
echo 'PASS snapshot/baseline difference is shown and blocks restore without explicit acceptance'
if TEST_NO_SNAPSHOT_DIFF=true bash "$HERE/restore-drill.sh" restore > "$TEMP/parameter-choice.txt" 2>&1; then
  echo 'FAIL parameter drift proceeded without an explicit current-group choice' >&2
  exit 1
fi
grep -F 'Parameter drift requires an explicit current-group choice or cancellation.' "$TEMP/parameter-choice.txt" >/dev/null
if grep -F 'rds restore-db-instance-from-db-snapshot --cli-input-json' "$TEMP/calls" >/dev/null; then
  echo 'FAIL parameter choice gate allowed a restore API request' >&2
  exit 1
fi
echo 'PASS parameter drift requires a separate current-group decision before restore'
if bash "$HERE/restore-drill.sh" harden-primary > "$TEMP/primary-param-check.txt" 2>&1; then
  echo 'FAIL restored-primary parameter drift was reported as validated' >&2
  exit 1
fi
grep -F 'Restored primary vs captured original primary' "$TEMP/primary-param-check.txt" >/dev/null
grep -F 'full parameter API differs from the captured primary' "$TEMP/primary-param-check.txt" >/dev/null
echo 'PASS post-restore primary validation compares all parameter API records and fails closed on drift'
if bash "$HERE/restore-drill.sh" harden-replica > "$TEMP/replica-param-check.txt" 2>&1; then
  echo 'FAIL new replica parameter drift was reported as validated' >&2
  exit 1
fi
grep -F 'New replica vs captured primary template' "$TEMP/replica-param-check.txt" >/dev/null
grep -F 'full parameter API differs from the captured primary template' "$TEMP/replica-param-check.txt" >/dev/null
echo 'PASS post-create replica validation compares all parameter records to the original primary template'
bash "$HERE/restore-drill.sh" preview > "$TEMP/default-preview.txt" 2>&1
grep -F 'Snapshot: snapshot-no-replica (source primary: primary-no-replica)' "$TEMP/default-preview.txt" >/dev/null
grep -F 'Primary restore request (populated fields only)' "$TEMP/default-preview.txt" >/dev/null
grep -F 'Role=primary' "$TEMP/default-preview.txt" >/dev/null
grep -F 'dr-restore=' "$TEMP/default-preview.txt" >/dev/null
echo 'PASS preview loads snapshot and restore targets from sandbox.env without repeated IDs'
bash "$HERE/restore-drill.sh" status > "$TEMP/status.txt" 2>&1
grep -F 'primary target: available' "$TEMP/status.txt" >/dev/null
grep -F 'replica target: available' "$TEMP/status.txt" >/dev/null
echo 'PASS read-only status checks both saved targets without requiring copied IDs'

steps="$(bash "$HERE/bb3-run.sh" --list)"
[[ "$steps" == *'P1-S02'* && "$steps" == *'P2-S00'* && "$steps" == *'P2-S07'* ]]
bash "$HERE/bb3-run.sh" S3 --only P2-S00,P2-S09 > "$TEMP/dispatcher-preview.txt" 2>&1
grep -F 'Snapshot: snapshot-no-replica (source primary: primary-no-replica)' "$TEMP/dispatcher-preview.txt" >/dev/null
grep -F 'primary target: available' "$TEMP/dispatcher-preview.txt" >/dev/null
echo 'PASS S3 --only comma list runs only the requested ordered step IDs'