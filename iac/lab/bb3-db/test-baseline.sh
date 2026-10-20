#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
mkdir -p "$TEMP/iac/lab/bb3-db"
cp "$HERE/capture-baseline.sh" "$TEMP/iac/lab/bb3-db/"
git() { [[ "$*" == *'check-ignore -q'* ]]; }
aws() {
  [[ "$1" == --profile && "$2" == offline && "$3" == --region && "$4" == ap-southeast-1 ]] || return 97
  shift 4
  printf '%s\n' "$*" >> "$CALLS"
  case "$1 $2" in
    'sts get-caller-identity') printf '%s\n' '{"Account":"000000000000","Arn":"arn:aws:iam::000000000000:user/offline"}' ;;
    'rds describe-db-instances')
      local db="$4" link='"ReadReplicaDBInstanceIdentifiers":["offline-replica"]'
      if [[ "$db" == offline-replica ]]; then
        link='"ReadReplicaSourceDBInstanceIdentifier":"offline-primary"'
        [[ "${TEST_FAILURE:-}" != topology ]] || link='"ReadReplicaSourceDBInstanceIdentifier":"wrong-primary"'
      elif [[ "${TEST_REPLICA:-}" == none ]]; then
        link='"ReadReplicaDBInstanceIdentifiers":[]'
      fi
      printf '{"DBInstances":[{"DBInstanceIdentifier":"%s","DBInstanceArn":"arn:aws:rds:ap-southeast-1:000000000000:db:%s","Engine":"postgres","EngineVersion":"17.9","DBParameterGroups":[{"DBParameterGroupName":"offline-pg"}],"DBSubnetGroup":{"DBSubnetGroupName":"offline-subnets"},"VpcSecurityGroups":[{"VpcSecurityGroupId":"sg-offline"}],%s}]}\n' "$db" "$db" "$link" ;;
    'rds list-tags-for-resource') printf '%s\n' '{"TagList":[]}' ;;
    'rds describe-db-parameter-groups') printf '%s\n' '{"DBParameterGroups":[{"DBParameterGroupFamily":"postgres17"}]}' ;;
    'rds describe-db-parameters')
      [[ "${TEST_FAILURE:-}" != parameters ]] || return 42
      printf '%s\n' '{"Parameters":[{"ParameterName":"max_connections","ParameterValue":"{DBInstanceClassMemory/9531392}","Source":"engine-default"}]}' ;;
    'rds describe-db-subnet-groups') printf '%s\n' '{"DBSubnetGroups":[{"Subnets":[{"SubnetIdentifier":"subnet-offline"}]}]}' ;;
    'ec2 describe-security-groups') printf '%s\n' '{"SecurityGroups":[{"GroupId":"sg-offline"}]}' ;;
    'ec2 describe-subnets') printf '%s\n' '{"Subnets":[{"SubnetId":"subnet-offline"}]}' ;;
    *) echo 'Forbidden or unexpected AWS action' >&2; return 98 ;;
  esac
}
export -f git aws
export AWS_PROFILE=offline AWS_REGION=ap-southeast-1 CALLS="$TEMP/calls"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
SCRIPT="$TEMP/iac/lab/bb3-db/capture-baseline.sh"
STORE="$TEMP/iac/lab/bb3-db/baselines"
capture_output="$(bash "$SCRIPT" offline-primary offline-replica)"
[[ "$capture_output" == *'Baseline at a glance:'* && "$capture_output" == *'Parameter group'* \
  && "$capture_output" == *'Tag app'* && "$capture_output" == *'User parameter overrides'* ]]
first="$(jq -r .directory "$STORE/latest.json")"
jq -e '.status == "complete"' "$STORE/latest.json" >/dev/null
jq -e '.Parameters[0].ParameterName == "max_connections"' "$STORE/$first/primary/parameters-1.json" >/dev/null
jq -e '.pgSettings == {} and .instance.EngineVersion == "17.9"' "$STORE/$first/replica/baseline.json" >/dev/null
while IFS=$'\t' read -r path expected; do
  actual="$(shasum -a 256 "$STORE/$first/$path")"
  [[ "${actual%% *}" == "$expected" ]]
done < <(jq -r '.files[] | [.path,.sha256] | @tsv' "$STORE/$first/manifest.json")
echo 'PASS complete raw capture, full parameters, compatibility JSON and all hashes'
show_output="$(bash "$SCRIPT" --show)"
[[ "$show_output" == *"Baseline at a glance: $STORE/$first"* && "$show_output" == *'Storage encrypted'* ]]
echo 'PASS latest baseline summary can be displayed without AWS calls'
bash "$SCRIPT" offline-primary offline-replica >/dev/null
second="$(jq -r .directory "$STORE/latest.json")"
[[ "$first" != "$second" && -f "$STORE/$first/capture.json" ]]
echo 'PASS refresh replaces latest reference but preserves prior capture'
for failure in parameters topology; do
  if TEST_FAILURE="$failure" bash "$SCRIPT" offline-primary offline-replica >/dev/null 2>&1; then exit 1; fi
  [[ "$(jq -r .directory "$STORE/latest.json")" == "$second" ]]
  echo "PASS $failure failure cannot replace latest complete baseline"
done
[[ "$(wc -l < "$CALLS")" -ge 40 ]]
echo 'PASS only pinned read-only AWS metadata actions executed'
mkdir -p "$TEMP/iac"
printf '%s\n' \
  'export BB3_SOURCE_PRIMARY_ID=offline-primary' \
  'export BB3_SOURCE_REPLICA_ID=offline-replica' > "$TEMP/iac/sandbox.env"
bash "$SCRIPT" >/dev/null
from_env="$(jq -r .directory "$STORE/latest.json")"
jq -e '.status=="complete" and .replica=="replica/baseline.json"' "$STORE/$from_env/capture.json" >/dev/null
echo 'PASS baseline capture reads discovered source IDs from sandbox.env'
TEST_REPLICA=none bash "$SCRIPT" offline-primary >/dev/null
single="$(jq -r .directory "$STORE/latest.json")"
jq -e '.status == "complete" and .replica == null' "$STORE/$single/capture.json" >/dev/null
[[ -f "$STORE/$single/primary/baseline.json" && ! -e "$STORE/$single/replica" ]]
echo 'PASS primary-only source capture records no replica'
if TEST_REPLICA=linked bash "$SCRIPT" offline-primary >/dev/null 2>&1; then
  echo 'FAIL incomplete primary-only topology capture was accepted' >&2
  exit 1
fi
echo 'PASS primary-only capture refuses when attached replicas are omitted'

ROOT="$(cd "$HERE/../../.." && pwd)"
RESTORE="$ROOT/automation/scripts/dr-restore.sh"
JQLIB="$(cat "$ROOT/automation/scripts/rds-requests.jq")"
for function in summary load_baseline overrides expected_json wanted_tags restore_request run_request describe harden cmd_snapshot cmd_pitr; do
  code="$(sed -n "/^$function() {/,/^}/p" "$RESTORE")"
  [[ -n "$code" ]]
  eval "$code"
done
export DR_DB_ACCESS=none DRY_RUN=1 DR_ENV=uat
BASELINE_DIR="$TEMP/restore-baselines"; OUT="$TEMP/requests"
mkdir -p "$BASELINE_DIR" "$OUT"
BASELINE_FILE="$BASELINE_DIR/baseline.json"
jq '{source:"offline-primary", capturedAt:"2026-10-19T00:00:00Z", tags:[], pgSettings:{}, instance:.}
    | .instance.BackupRetentionPeriod=7' "$ROOT/tests/local/fixtures/rds-primary-uat-like.json" > "$BASELINE_FILE"
RET_FLOOR=7
unset DB_INSTANCE_CLASS DB_SUBNET_GROUP DB_SG DB_PARAM_GROUP MULTI_AZ EXTRA_TAGS DR_TIMELINE SOURCE_DB
PRIMARY_DB=offline-primary
aws() {
  [[ "$1" == --profile && "$2" == offline && "$3" == --region && "$4" == ap-southeast-1 ]] || return 97
  shift 4
  printf '%s\n' "$*" >> "$CALLS"
  case "$1 $2" in
    'rds restore-db-instance-from-db-snapshot'|'rds restore-db-instance-to-point-in-time')
      [[ "$*" == "rds $2 --generate-cli-skeleton input" ]] || return 98
      case "$CAPABILITY" in
        new) printf '%s\n' '{"BackupRetentionPeriod":0,"PreferredBackupWindow":""}' ;;
        old) printf '%s\n' '{}' ;;
        retention) printf '%s\n' '{"BackupRetentionPeriod":0}' ;;
        window) printf '%s\n' '{"PreferredBackupWindow":""}' ;;
        mixed)
          if [[ "$2" == restore-db-instance-from-db-snapshot ]]; then printf '%s\n' '{"BackupRetentionPeriod":0}'
          else printf '%s\n' '{"PreferredBackupWindow":""}'; fi ;;
        failed) return 42 ;;
        invalid) printf '%s\n' '[]' ;;
        *) return 98 ;;
      esac ;;
    'rds describe-db-snapshots')
      printf '%s\n' '{"DBInstanceIdentifier":"offline-primary","SnapshotCreateTime":"2026-10-18T00:00:00Z","AllocatedStorage":20}' ;;
    'rds describe-db-instances')
      expected_json | jq '.BackupRetentionPeriod=1 | .PreferredBackupWindow="01:00-01:30"' ;;
    'rds list-tags-for-resource') printf '%s\n' '[]' ;;
    *) echo "Forbidden or unexpected AWS action: $*" >&2; return 98 ;;
  esac
}
psql() { echo 'Forbidden SQL' >&2; return 98; }
dr_dsn() { echo 'Forbidden credential lookup' >&2; return 98; }
for CAPABILITY in new old retention window mixed; do
  for operation in snapshot pitr; do
    request="$OUT/restore-request-offline-new.json"
    if [[ "$operation" == snapshot ]]; then
      cmd_snapshot offline-snapshot offline-new > "$TEMP/restore.log" 2> "$TEMP/compat.log"
      op='{"DBInstanceIdentifier":"offline-new","DBSnapshotIdentifier":"offline-snapshot"}'
      from=offline-primary@offline-snapshot
      api=restore-db-instance-from-db-snapshot
    else
      cmd_pitr offline-primary offline-new latest > "$TEMP/restore.log" 2> "$TEMP/compat.log"
      op="$(jq -n --argjson instance "$(expected_json)" '{TargetDBInstanceIdentifier:"offline-new",SourceDBInstanceIdentifier:"offline-primary",UseLatestRestorableTime:true}
        + ({AllocatedStorage:$instance.AllocatedStorage,MaxAllocatedStorage:$instance.MaxAllocatedStorage} | with_entries(select(.value != null)))')"
      from=offline-primary@latest
      api=restore-db-instance-to-point-in-time
    fi
    supported_retention=false; supported_window=false
    case "$CAPABILITY:$operation" in new:*|retention:*|mixed:snapshot) supported_retention=true ;; esac
    case "$CAPABILITY:$operation" in new:*|window:*|mixed:pitr) supported_window=true ;; esac
    raw="$(jq --argjson op "$op" --argjson tags "$(wanted_tags "$from")" "$JQLIB"' restore_req($op; $tags)' <<<"$(expected_json)")"
    jq -e --argjson raw "$raw" --argjson retention "$supported_retention" --argjson window "$supported_window" '
      . == ($raw | if $retention then . else del(.BackupRetentionPeriod) end
                 | if $window then . else del(.PreferredBackupWindow) end)
      and (if $retention then .BackupRetentionPeriod == 7 else has("BackupRetentionPeriod") | not end)
      and (if $window then .PreferredBackupWindow == $raw.PreferredBackupWindow else has("PreferredBackupWindow") | not end)' "$request" >/dev/null
    grep -F "rds $api --generate-cli-skeleton input" "$CALLS" >/dev/null
    if [[ "$CAPABILITY" == new ]]; then [[ ! -s "$TEMP/compat.log" ]]
    else
      grep -F 'INFO ' "$TEMP/compat.log" >/dev/null
      grep -F 'post-restore harden will apply' "$TEMP/compat.log" >/dev/null
      if [[ "$supported_retention" == false ]]; then grep -F BackupRetentionPeriod "$TEMP/compat.log" >/dev/null; fi
      if [[ "$supported_window" == false ]]; then grep -F PreferredBackupWindow "$TEMP/compat.log" >/dev/null; fi
    fi
    harden offline-new > "$TEMP/harden.log"
    jq -e --argjson expected "$(expected_json)" '.BackupRetentionPeriod == 7 and .PreferredBackupWindow == $expected.PreferredBackupWindow' \
      "$OUT/harden-request-offline-new.json" >/dev/null
    echo "PASS $operation $CAPABILITY CLI: only unsupported backup inputs deferred, harden retains 7 and window"
  done
done
for retention in 1 14; do
  jq --argjson retention "$retention" '.instance.BackupRetentionPeriod=$retention' "$BASELINE_FILE" > "$TEMP/baseline.json"
  BASE="$TEMP/baseline.json"
  CAPABILITY=new
  restore_request '{"DBInstanceIdentifier":"offline-new","DBSnapshotIdentifier":"offline-snapshot"}' offline-primary restore-db-instance-from-db-snapshot > "$TEMP/floor.json"
  jq -e --argjson retention "$retention" '.BackupRetentionPeriod == ([7,$retention] | max)' "$TEMP/floor.json" >/dev/null
  jq -e --argjson retention "$retention" '.instance.BackupRetentionPeriod == $retention' "$BASE" >/dev/null
done
echo 'PASS retention floor preserves source values and does not lower longer retention'
for CAPABILITY in failed invalid; do
  if restore_request '{"DBInstanceIdentifier":"offline-new"}' offline-primary restore-db-instance-from-db-snapshot > "$TEMP/rejected.json" 2>/dev/null; then exit 1; fi
  [[ ! -s "$TEMP/rejected.json" ]]
done
echo 'PASS failed or invalid CLI skeleton fails closed without a restore request'