#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TEMP="$(mktemp -d)"
TEMP="$(cd "$TEMP" && pwd -P)"
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
    VpcSecurityGroups:[{VpcSecurityGroupId:"sg-original"},{VpcSecurityGroupId:"sg-primary-extra"}],DBInstanceClass:"db.t4g.micro",
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
      local instance='{"DBInstanceIdentifier":"primary-no-replica","DBInstanceArn":"arn:aws:rds:ap-southeast-1:000000000000:db:primary-no-replica","DBInstanceStatus":"available","ReadReplicaDBInstanceIdentifiers":[],"DBParameterGroups":[{"DBParameterGroupName":"pg-original","ParameterApplyStatus":"in-sync"}],"DBSubnetGroup":{"DBSubnetGroupName":"subnets-original","VpcId":"vpc-original"},"VpcSecurityGroups":[{"VpcSecurityGroupId":"sg-original"},{"VpcSecurityGroupId":"sg-primary-extra"}],"DBInstanceClass":"db.t4g.micro","AvailabilityZone":"ap-southeast-1a","PubliclyAccessible":false,"MultiAZ":false,"BackupRetentionPeriod":7,"PreferredBackupWindow":"18:00-18:30","PreferredMaintenanceWindow":"sun:19:00-sun:19:30","Endpoint":{"Port":5432},"Engine":"postgres","EngineVersion":"17.9","AllocatedStorage":20,"StorageEncrypted":false,"DBName":"app","MasterUsername":"sandbox_admin","DeletionProtection":false,"CopyTagsToSnapshot":true,"AutoMinorVersionUpgrade":true,"IAMDatabaseAuthenticationEnabled":false,"NetworkType":"IPV4","EnabledCloudwatchLogsExports":[]}'
      if [[ "$*" == *'--db-instance-identifier replica-target'* ]]; then
        instance='{"DBInstanceIdentifier":"replica-target","DBInstanceArn":"arn:aws:rds:ap-southeast-1:000000000000:db:replica-target","ReadReplicaSourceDBInstanceIdentifier":"restore-primary","DBInstanceStatus":"available","DBParameterGroups":[{"DBParameterGroupName":"pg-original","ParameterApplyStatus":"in-sync"}],"DBSubnetGroup":{"DBSubnetGroupName":"subnets-original","VpcId":"vpc-original"},"VpcSecurityGroups":[{"VpcSecurityGroupId":"sg-original"}],"DBInstanceClass":"db.t4g.micro","AvailabilityZone":"ap-southeast-1b","PubliclyAccessible":false,"BackupRetentionPeriod":0,"PreferredMaintenanceWindow":"sun:19:00-sun:19:30","Endpoint":{"Port":5432},"Engine":"postgres","EngineVersion":"17.9","AllocatedStorage":20,"StorageEncrypted":false,"DeletionProtection":false,"CopyTagsToSnapshot":true,"AutoMinorVersionUpgrade":true,"IAMDatabaseAuthenticationEnabled":false,"NetworkType":"IPV4","EnabledCloudwatchLogsExports":[]}'
      elif [[ "$*" == *'--db-instance-identifier restore-primary'* ]]; then
        instance="${instance/primary-no-replica/restore-primary}"
      fi
      if [[ "${TEST_LIVE_QUARANTINE:-}" == true && "$*" == *'--db-instance-identifier primary-no-replica'* ]]; then
        instance="$(jq '.VpcSecurityGroups=[{VpcSecurityGroupId:"sg-run-quarantine"}]' <<< "$instance")"
      fi
      if [[ "$*" == *'--query DBInstances[0]'* ]]; then printf '%s\n' "$instance"; else printf '{"DBInstances":[%s]}\n' "$instance"; fi ;;
    'rds describe-db-parameter-groups') printf '%s\n' 'postgres17' ;;
    'rds describe-db-parameters')
      if [[ "$*" == *'--source user'* ]]; then
        printf '%s\n' '[]'
      elif [[ "${TEST_PARAMETERS_MATCH:-}" == true ]]; then
        printf '%s\n' '{"Parameters":[{"ParameterName":"max_connections","ParameterValue":"100","Source":"user"}]}'
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
    'rds modify-db-instance')
      [[ "$*" == *'--generate-cli-skeleton input'* ]] || return 98
      jq -nc '{DBInstanceIdentifier:"",VpcSecurityGroupIds:[],DBParameterGroupName:"",PreferredMaintenanceWindow:"",ApplyImmediately:false}' ;;
    *) echo "Unexpected AWS call: $*" >&2; return 98 ;;
  esac
}
export -f git aws
export BB3_RESTORE_CONFIG="$TEMP/sandbox.env" BB3_RESTORE_BASELINE_DIR="$BASELINE_STORE" TEST_CALLS="$TEMP/calls"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
CONFIG_FIXTURE="$TEMP/config-override"
mkdir -p "$CONFIG_FIXTURE/iac/lab/bb3-db" "$CONFIG_FIXTURE/automation/scripts"
cp "$HERE/restore-drill.sh" "$HERE/bb3-prompt.sh" "$CONFIG_FIXTURE/iac/lab/bb3-db/"
cp "$HERE/../../../automation/scripts/rds-requests.jq" "$CONFIG_FIXTURE/automation/scripts/"
[[ ! -e "$CONFIG_FIXTURE/iac/sandbox.env" ]]
TEST_PARAMETERS_MATCH=true TEST_NO_SNAPSHOT_DIFF=true \
  bash "$CONFIG_FIXTURE/iac/lab/bb3-db/restore-drill.sh" preview snapshot-no-replica restore-primary replica-target \
  > "$TEMP/config-override.txt" 2>&1
: > "$TEST_CALLS"
echo 'PASS restore config override works without a default sandbox file'

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
[[ "$replica_table" == *'sg-primary-extra'* ]]
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
if TEST_PARAMETERS_MATCH=true bash "$HERE/restore-drill.sh" harden-replica > "$TEMP/replica-sg-check.txt" 2>&1; then
  echo 'FAIL replica SG mismatch was not gated for review' >&2
  exit 1
fi
grep -F 'VpcSecurityGroupIds' "$TEMP/replica-sg-check.txt" >/dev/null
grep -F 'sg-primary-extra' "$TEMP/replica-sg-check.txt" >/dev/null
grep -F 'Confirmation requires an interactive terminal.' "$TEMP/replica-sg-check.txt" >/dev/null
if grep -F 'rds modify-db-instance --cli-input-json' "$TEMP/calls" >/dev/null; then
  echo 'FAIL replica SG test submitted a modify request' >&2
  exit 1
fi
echo 'PASS replica SG parity is shown as a reviewed hardening change before mutation'
bash "$HERE/restore-drill.sh" preview > "$TEMP/default-preview.txt" 2>&1
grep -F 'Snapshot: snapshot-no-replica (source primary: primary-no-replica)' "$TEMP/default-preview.txt" >/dev/null
grep -F 'Primary restore request (populated fields only)' "$TEMP/default-preview.txt" >/dev/null
grep -F 'Role=primary' "$TEMP/default-preview.txt" >/dev/null
grep -F 'dr-restore=' "$TEMP/default-preview.txt" >/dev/null
echo 'PASS preview loads snapshot and restore targets from sandbox.env without repeated IDs'
TEST_LIVE_QUARANTINE=true bash "$HERE/restore-drill.sh" preview > "$TEMP/quarantined-source-preview.txt" 2>&1
grep -F 'VpcSecurityGroupIds        | sg-original,sg-primary-extra' "$TEMP/quarantined-source-preview.txt" >/dev/null
if grep -F 'sg-run-quarantine' "$TEMP/quarantined-source-preview.txt" >/dev/null; then
  echo 'FAIL restore preview inherited the early source quarantine SG' >&2
  exit 1
fi
echo 'PASS restore preview uses the captured pre-fence SG baseline while the live source is quarantined'
bash "$HERE/restore-drill.sh" status > "$TEMP/status.txt" 2>&1
grep -F 'primary target: available' "$TEMP/status.txt" >/dev/null
grep -F 'replica target: available' "$TEMP/status.txt" >/dev/null
echo 'PASS read-only status checks both saved targets without requiring copied IDs'

steps="$(bash "$HERE/bb3-run.sh" --list)"
[[ "$steps" == *'P0-S01'* && "$steps" == *'P0-S02'* && "$steps" == *'P0-S03'* \
  && "$steps" == *'P1-S01-1'* && "$steps" == *'P1-S01-2'* \
  && "$steps" == *'P2-S00'* && "$steps" == *'P2-S07'* ]]
bash "$HERE/bb3-run.sh" S3 --only P2-S00,P2-S09 > "$TEMP/dispatcher-preview.txt" 2>&1
grep -F 'Snapshot: snapshot-no-replica (source primary: primary-no-replica)' "$TEMP/dispatcher-preview.txt" >/dev/null
grep -F 'primary target: available' "$TEMP/dispatcher-preview.txt" >/dev/null
echo 'PASS S3 --only comma list runs only the requested ordered step IDs'

bash "$HERE/bb3-run.sh" S3 --only P2-S09 > "$TEMP/default-preview.txt" 2>&1
grep -F '  What: Inspect both saved restore targets.' "$TEMP/default-preview.txt" >/dev/null
grep -F '  Expected:' "$TEMP/default-preview.txt" >/dev/null
grep -F 'This selection stops before application recovery.' "$TEMP/default-preview.txt" >/dev/null
grep -F 'S3 --from P3-S01 --to P5' "$TEMP/default-preview.txt" >/dev/null
bash "$HERE/bb3-run.sh" S3 --verbose --only P2-S09 > "$TEMP/verbose-preview.txt" 2>&1
grep -F '  What:' "$TEMP/verbose-preview.txt" >/dev/null
grep -F 'Simulate app failure by cutting off new DB traffic' <<< "$steps" >/dev/null
while IFS= read -r step; do
  grep -F "    $step) action=" "$HERE/bb3-run.sh" >/dev/null \
    || { echo "Missing What/Expected description for $step" >&2; exit 1; }
done < <(awk '$1 ~ /^P[0-9]/ {print $1}' <<< "$steps")
echo 'PASS every step has What/Expected descriptions; default output and RDS-only handoff are visible'

range_steps="$(bash "$HERE/bb3-run.sh" S3 --from P2-S06 --to P2-S09 --list)"
[[ "$range_steps" == $'Selected BB3 steps (no actions run):\n  P2-S06\n  P2-S07\n  P2-S08\n  P2-S09' ]]
range_steps="$(bash "$HERE/bb3-run.sh" S3 --to P1-S01-2 --from P1-S01-1 --list)"
[[ "$range_steps" == $'Selected BB3 steps (no actions run):\n  P1-S01-1\n  P1-S01-2' ]]
range_steps="$(bash "$HERE/bb3-run.sh" S3 --from P4-S01 --list)"
[[ "$range_steps" == $'Selected BB3 steps (no actions run):\n  P4-S01\n  P4-S02' ]]
range_steps="$(bash "$HERE/bb3-run.sh" S3 --to P0-S02 --list)"
[[ "$range_steps" == $'Selected BB3 steps (no actions run):\n  P0-S01\n  P0-S02' ]]
bash "$HERE/bb3-run.sh" S3 --from P2-S09 --to P2-S09 > "$TEMP/range-status.txt" 2>&1
grep -F 'primary target: available' "$TEMP/range-status.txt" >/dev/null
grep -F 'replica target: available' "$TEMP/range-status.txt" >/dev/null
reject_selection() {
  if bash "$HERE/bb3-run.sh" S3 "$@" > "$TEMP/invalid-selection.txt" 2>&1; then
    printf 'FAIL runner accepted invalid selection: %s\n' "$*" >&2
    exit 1
  fi
  if grep -F '== P' "$TEMP/invalid-selection.txt" >/dev/null; then
    echo 'FAIL runner started a step before rejecting invalid selection' >&2
    exit 1
  fi
}
reject_selection --from P2-S09 --to P2-S06
reject_selection --from P3-G0
reject_selection --to P5-S99
reject_selection --from
reject_selection --to ''
reject_selection --from P2-S09 --from P2-S09
reject_selection --from P2-S09 --only P2-S09
reject_selection --only P2-S09 --to P2-S09
reject_selection --only P0-S03,unknown
range_steps="$(bash "$HERE/bb3-run.sh" S3 --from P4-G4 --to P5 --list)"
[[ "$range_steps" == $'Selected BB3 steps (no actions run):\n  P4-G4\n  P5' ]]
range_steps="$(bash "$HERE/bb3-run.sh" S3 --list --only P5)"
[[ "$range_steps" == $'Selected BB3 steps (no actions run):\n  P5' ]]
reject_selection --from P5 --to P4-S02
echo 'PASS inclusive ranges, one-sided defaults, split step IDs, and fail-before-action validation'

export TEST_SECRET_SCRIPT="$HERE/secret-endpoints.sh"
cat > "$TEMP/endpoint-dispatch.bash" <<'EOF'
bash() {
  if [[ "$1" == "$TEST_SECRET_SCRIPT" ]]; then
    shift
    printf 'ENDPOINT_ARGS'
    printf ' <%s>' "$@"
    printf '\n'
  else
    command bash "$@"
  fi
}
EOF
BASH_ENV="$TEMP/endpoint-dispatch.bash" command bash "$HERE/bb3-run.sh" S3 --from P3-S02 --to P3-S02 > "$TEMP/range-endpoints.txt" 2>&1
grep -Fx 'ENDPOINT_ARGS <--apply>' "$TEMP/range-endpoints.txt" >/dev/null
BASH_ENV="$TEMP/endpoint-dispatch.bash" command bash "$HERE/bb3-run.sh" S3 --only P3-S02 --preview > "$TEMP/preview-endpoints.txt" 2>&1
grep -Fx 'ENDPOINT_ARGS <--preview>' "$TEMP/preview-endpoints.txt" >/dev/null
BASH_ENV="$TEMP/endpoint-dispatch.bash" command bash "$HERE/bb3-run.sh" S3 --only P3-S02 --failback DR-fixture --preview \
  > "$TEMP/single-failback-preview.txt" 2>&1
grep -Fx 'ENDPOINT_ARGS <--failback> <DR-fixture> <--preview>' "$TEMP/single-failback-preview.txt" >/dev/null
grep -F 'What: Preview failback: show current restored endpoints and the saved original return endpoints (read-only).' \
  "$TEMP/single-failback-preview.txt" >/dev/null
! grep -F 'Both endpoints match the selected restored pair' "$TEMP/single-failback-preview.txt" >/dev/null
BASH_ENV="$TEMP/endpoint-dispatch.bash" command bash "$HERE/bb3-run.sh" S3 --only P3-S02 --apply > "$TEMP/apply-endpoints.txt" 2>&1
grep -Fx 'ENDPOINT_ARGS <--apply>' "$TEMP/apply-endpoints.txt" >/dev/null
BASH_ENV="$TEMP/endpoint-dispatch.bash" command bash "$HERE/bb3-run.sh" S3 --only P3-S02 > "$TEMP/default-endpoints.txt" 2>&1
! grep -F '<--apply>' "$TEMP/default-endpoints.txt" >/dev/null
echo 'PASS ranges select guarded endpoint apply; single-step preview/apply arguments stay explicit'

FIXTURE_ROOT="$TEMP/full-run"
mkdir -p "$FIXTURE_ROOT/iac/lab/bb3-db"
cp "$HERE/bb3-run.sh" "$FIXTURE_ROOT/iac/lab/bb3-db/bb3-run.sh"
cp "$HERE/bb3-prompt.sh" "$HERE/bb3-wait.py" "$FIXTURE_ROOT/iac/lab/bb3-db/"
cp "$HERE/runner-progress.py" "$HERE/closeout.py" "$HERE/secret-endpoints.py" "$FIXTURE_ROOT/iac/lab/bb3-db/"
printf '%s\n' 'TF_VAR_account_id=000000000000' 'TF_VAR_aws_profile=lab_sandbox' \
  'TF_VAR_region=ap-southeast-1' 'ENV=uat' 'BB3_RESTORE_TARGET_PRIMARY_ID=fixture-primary' \
  'BB3_RESTORE_TARGET_REPLICA_ID=fixture-replica' > "$FIXTURE_ROOT/iac/sandbox.env"
cat > "$TEMP/full-dispatch.bash" <<'EOF'
bash() {
  local helper="${1##*/}"
  shift
  printf 'MOCK_STEP %s' "$helper"
  printf ' <%s>' "$@"
  printf '\n'
  if [[ "$helper" == closeout.sh && "${1:-}" == package && -n "${TEST_REWRITE_RUNNER:-}" ]]; then
    printf '\nprintf "unterminated\n' >> "$TEST_REWRITE_RUNNER"
  fi
  [[ "$helper" != "${TEST_STOP_HELPER:-}" ]]
}
aws() {
  case "$*" in
    *'sts get-caller-identity'*) echo 000000000000 ;;
    *'rds wait db-instance-available'*) return 0 ;;
    *) echo 'Unexpected AWS call in full-run fixture' >&2; return 99 ;;
  esac
}
EOF
BASH_ENV="$TEMP/full-dispatch.bash" command bash "$FIXTURE_ROOT/iac/lab/bb3-db/bb3-run.sh" S3 \
  > "$TEMP/full-run.txt" 2>&1
actual_steps="$(awk '/^== P/ {print $2}' "$TEMP/full-run.txt")"
expected_steps="$(awk '$1 ~ /^P[0-9]/ {print $1}' <<< "$steps")"
[[ "$actual_steps" == "$expected_steps" ]]
grep -Fx 'MOCK_STEP secret-endpoints.sh <--apply>' "$TEMP/full-run.txt" >/dev/null
grep -Fx 'MOCK_STEP closeout.sh <declare>' "$TEMP/full-run.txt" >/dev/null
grep -Fx 'MOCK_STEP closeout.sh <package>' "$TEMP/full-run.txt" >/dev/null
! grep -F 'MOCK_STEP retire-restored.sh' "$TEMP/full-run.txt" >/dev/null
if TEST_STOP_HELPER=fence-confirm.sh BASH_ENV="$TEMP/full-dispatch.bash" \
    command bash "$FIXTURE_ROOT/iac/lab/bb3-db/bb3-run.sh" S3 --new > "$TEMP/blocked-full-run.txt" 2>&1; then
  echo 'FAIL full recovery continued past a failed fence gate' >&2
  exit 1
fi
! grep -F '== P3-S02 ==' "$TEMP/blocked-full-run.txt" >/dev/null
! grep -F '== P5 ==' "$TEMP/blocked-full-run.txt" >/dev/null
echo 'PASS plain S3 runs every recovery step through T10/P5, selects guarded apply and stops on gate failure'

TEST_REWRITE_RUNNER="$FIXTURE_ROOT/iac/lab/bb3-db/bb3-run.sh" BASH_ENV="$TEMP/full-dispatch.bash" \
  command bash "$FIXTURE_ROOT/iac/lab/bb3-db/bb3-run.sh" S3 --new > "$TEMP/edited-full-run.txt" 2>&1
grep -Fx 'MOCK_STEP closeout.sh <package>' "$TEMP/edited-full-run.txt" >/dev/null
! grep -F 'unexpected EOF' "$TEMP/edited-full-run.txt" >/dev/null
if command bash -n "$FIXTURE_ROOT/iac/lab/bb3-db/bb3-run.sh" > "$TEMP/edited-syntax.txt" 2>&1; then
  echo 'FAIL mid-run edit fixture did not contain a syntax error' >&2
  exit 1
fi
echo 'PASS runner exits after packaging without parsing a mid-run edited tail'

cp "$HERE/bb3-run.sh" "$FIXTURE_ROOT/iac/lab/bb3-db/bb3-run.sh"
BASH_ENV="$TEMP/full-dispatch.bash" command bash "$FIXTURE_ROOT/iac/lab/bb3-db/bb3-run.sh" S3 --failback DR-fixture \
  > "$TEMP/full-failback.txt" 2>&1
actual_failback="$(grep '^MOCK_STEP ' "$TEMP/full-failback.txt")"
expected_failback='MOCK_STEP secret-endpoints.sh <--failback> <DR-fixture> <--preview>
MOCK_STEP fence-confirm.sh <--failback> <DR-fixture>
MOCK_STEP secret-endpoints.sh <--failback> <DR-fixture> <--apply>
MOCK_STEP fence-confirm.sh <--failback> <DR-fixture> <--release-quarantine>
MOCK_STEP app-deploy-confirm.sh <--failback> <DR-fixture>
MOCK_STEP app-recovery-confirm.sh <connectivity> <--failback> <DR-fixture>
MOCK_STEP app-recovery-confirm.sh <e2e> <--failback> <DR-fixture>'
[[ "$actual_failback" == "$expected_failback" ]]
for description in \
  'What: Preview failback:' \
  'What: Fence the restored DB pair for failback' \
  'What: Apply failback: return both app secret endpoints' \
  'What: Release the original DB pair quarantine' \
  'What: Record manual app deployment and service convergence on the original DB endpoint pair.' \
  'What: Record app-owner health confirmation on the original primary/replica endpoint pair.' \
  'What: Record or reuse the original-path business transaction/readback'; do
  grep -F "$description" "$TEMP/full-failback.txt" >/dev/null
done
! grep -F 'Both endpoints match the selected restored pair' "$TEMP/full-failback.txt" >/dev/null
[[ "$(grep -c '  Expected:' "$TEMP/full-failback.txt")" == 7 ]]
BASH_ENV="$TEMP/full-dispatch.bash" command bash "$FIXTURE_ROOT/iac/lab/bb3-db/bb3-run.sh" \
  S3 --only P3-S01 --failback DR-fixture --cleanup-failback-quarantine > "$TEMP/cleanup-description.txt" 2>&1
grep -F 'What: Delete only the detached restored-pair failback quarantine SG.' "$TEMP/cleanup-description.txt" >/dev/null
grep -F 'never retires DBs or deletes snapshots/backups' "$TEMP/cleanup-description.txt" >/dev/null
BASH_ENV="$TEMP/full-dispatch.bash" command bash "$FIXTURE_ROOT/iac/lab/bb3-db/bb3-run.sh" \
  S3 --only P3-S02 --failback DR-fixture --apply > "$TEMP/single-failback-apply.txt" 2>&1
grep -F 'What: Apply failback: return both app secret endpoints from the restored pair to the original pair.' \
  "$TEMP/single-failback-apply.txt" >/dev/null
BASH_ENV="$TEMP/full-dispatch.bash" command bash "$FIXTURE_ROOT/iac/lab/bb3-db/bb3-run.sh" \
  S3 --only P3-S02 --failback DR-fixture --apply --preview > "$TEMP/last-flag-preview.txt" 2>&1
grep -F 'What: Preview failback:' "$TEMP/last-flag-preview.txt" >/dev/null
! grep -F 'What: Apply failback:' "$TEMP/last-flag-preview.txt" >/dev/null
echo 'PASS failback descriptions distinguish all seven actions, SG-only cleanup and explicit preview/apply mode'
! grep -F '== P0-' "$TEMP/full-failback.txt" >/dev/null
! grep -F 'MOCK_STEP restore-drill.sh' "$TEMP/full-failback.txt" >/dev/null
if TEST_STOP_HELPER=fence-confirm.sh BASH_ENV="$TEMP/full-dispatch.bash" \
    command bash "$FIXTURE_ROOT/iac/lab/bb3-db/bb3-run.sh" S3 --failback DR-fixture \
    > "$TEMP/blocked-failback.txt" 2>&1; then
  echo 'FAIL guided failback continued past a failed fence gate' >&2
  exit 1
fi
! grep -F '<--apply>' "$TEMP/blocked-failback.txt" >/dev/null
! grep -F 'MOCK_STEP app-deploy-confirm.sh' "$TEMP/blocked-failback.txt" >/dev/null
plan="$(command bash "$HERE/bb3-run.sh" S3 --failback DR-fixture --list)"
grep -F 'FB-04  P3-S01 --release-quarantine' <<< "$plan" >/dev/null
! grep -F '== P' <<< "$plan" >/dev/null
reject_selection --failback latest
reject_selection --failback
reject_selection --failback DR-fixture --to P5
reject_selection --from P3-S01 --failback DR-fixture
reject_selection --failback DR-fixture --only P3-S01
reject_selection --failback DR-fixture --failback DR-other
echo 'PASS guided failback preserves exact ordering/run ID, stops at fence failure and rejects unsafe selectors'