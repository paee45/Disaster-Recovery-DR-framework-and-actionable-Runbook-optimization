#!/usr/bin/env bash
set -euo pipefail
set +x
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
else
  GREEN=''; RED=''; YELLOW=''; RESET=''
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
JQ_LIBRARY="$(<"$ROOT/automation/scripts/rds-requests.jq")"
usage() {
  cat >&2 <<'EOF'
Usage:
  bash iac/lab/bb3-db/restore-drill.sh <preview|status|restore|harden-primary|replica|harden-replica> [snapshot-id [restore-primary-id [restore-replica-id]]]

preview is read-only. restore creates a standalone primary from the snapshot.
status is read-only and checks both saved restore targets.
harden-primary attaches the captured parameter group if restore did not apply it.
replica creates a new read replica after the restored primary is available.
harden-replica applies captured parameter/maintenance settings after replica availability.
Omitted IDs come from the reviewed selections in iac/sandbox.env. Positional IDs override them.
Every mutating action displays its comparison table and defaults to No at confirmation.
EOF
  exit 2
}
[[ $# -ge 1 && $# -le 4 ]] || usage
MODE="$1"; shift
[[ "$MODE" =~ ^(preview|status|restore|harden-primary|replica|harden-replica)$ ]] || usage

CONFIG="$ROOT/iac/sandbox.env"
[[ -f "$CONFIG" ]] || { echo 'Missing ignored iac/sandbox.env.' >&2; exit 2; }
git -C "$ROOT" check-ignore -q "$CONFIG" || { echo 'Refusing non-ignored sandbox config.' >&2; exit 2; }
[[ -z "${AWS_ACCESS_KEY_ID:-}${AWS_SECRET_ACCESS_KEY:-}${AWS_SESSION_TOKEN:-}" ]] \
  || { echo 'Unset exported AWS credentials; use the configured named profile.' >&2; exit 2; }
# shellcheck source=/dev/null
source "${BB3_RESTORE_CONFIG:-$CONFIG}"
unset TF_VAR_terrakube_token AWS_DEFAULT_PROFILE
SNAPSHOT_ID="${1:-${BB3_SNAPSHOT_ID:-}}"
TARGET_PRIMARY="${2:-${BB3_RESTORE_TARGET_PRIMARY_ID:-}}"
TARGET_REPLICA="${3:-${BB3_RESTORE_TARGET_REPLICA_ID:-}}"
[[ "$SNAPSHOT_ID" =~ ^[A-Za-z0-9][A-Za-z0-9:_-]*$ ]] || { echo 'Invalid or missing snapshot identifier; run discovery first.' >&2; exit 2; }
for id in "$TARGET_PRIMARY" "$TARGET_REPLICA"; do
  [[ "$id" =~ ^[A-Za-z][A-Za-z0-9-]{0,62}$ ]] || { echo 'Invalid or missing target DB identifier; run discovery first.' >&2; exit 2; }
done
[[ "$TARGET_PRIMARY" != "$TARGET_REPLICA" ]] || { echo 'Primary and replica targets must differ.' >&2; exit 2; }
PROFILE="${TF_VAR_aws_profile:-}"
REGION="${TF_VAR_region:-}"
ACCOUNT="${TF_VAR_account_id:-}"
[[ "$PROFILE" =~ ^(lab_sandbox|pa_aws_sandbox|pa_iam_aws_sandbox)$ && "$REGION" == ap-southeast-1 \
  && "$ACCOUNT" =~ ^[0-9]{12}$ ]] || { echo 'Sandbox profile, account or region is invalid.' >&2; exit 2; }
awsx() { aws --profile "$PROFILE" --region "$REGION" --no-cli-pager "$@"; }
CALLER_ACCOUNT="$(awsx sts get-caller-identity --query Account --output text)"
[[ "$CALLER_ACCOUNT" == "$ACCOUNT" ]] || { echo 'AWS caller does not match the configured sandbox account.' >&2; exit 2; }

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else echo 'REFUSED: sha256sum or shasum is required to verify the baseline.' >&2; return 2
  fi
}

verify_capture_member() {
  local relative="$1" expected actual
  expected="$(jq -er --arg path "$relative" '.files[] | select(.path==$path) | .sha256' "$CAPTURE_DIRECTORY/manifest.json")" \
    || { echo "REFUSED: baseline manifest has no hash for $relative." >&2; return 2; }
  [[ "$expected" =~ ^[a-fA-F0-9]{64}$ && -f "$CAPTURE_DIRECTORY/$relative" ]] \
    || { echo "REFUSED: baseline file is missing or has an invalid hash entry: $relative." >&2; return 2; }
  actual="$(hash_file "$CAPTURE_DIRECTORY/$relative")"
  [[ "$actual" == "$expected" ]] || { echo "REFUSED: baseline integrity check failed: $relative." >&2; return 2; }
}

if [[ "$MODE" == status ]]; then
  for role in primary replica; do
    target="$TARGET_PRIMARY"; [[ "$role" != replica ]] || target="$TARGET_REPLICA"
    if ! instance="$(awsx rds describe-db-instances --db-instance-identifier "$target" --query 'DBInstances[0]' --output json 2>/dev/null)"; then
      printf '%s target %s: not found or unavailable to query\n' "$role" "$target"
      continue
    fi
    jq -r --arg role "$role" '
      "\($role) target: \(.DBInstanceStatus) | class=\(.DBInstanceClass) | parameterGroup=\(.DBParameterGroups[0].DBParameterGroupName // "not set") | parameterApply=\(.DBParameterGroups[0].ParameterApplyStatus // "unknown")"
    ' <<<"$instance"
  done
  exit 0
fi

snapshot="$(awsx rds describe-db-snapshots --db-snapshot-identifier "$SNAPSHOT_ID" --output json)"
[[ "$(jq -r '.DBSnapshots | length' <<<"$snapshot")" == 1 ]] || { echo 'Snapshot was not found uniquely.' >&2; exit 2; }
[[ "$(jq -r '.DBSnapshots[0].Status' <<<"$snapshot")" == available ]] || { echo 'Snapshot is not available.' >&2; exit 2; }
snapshot_record="$(jq -c '.DBSnapshots[0]' <<<"$snapshot")"
SOURCE_PRIMARY="$(jq -er '.DBSnapshots[0].DBInstanceIdentifier' <<<"$snapshot")"
snapshot_arn="$(jq -r '.DBSnapshotArn // empty' <<<"$snapshot_record")"
[[ -n "$snapshot_arn" ]] || { echo 'Snapshot ARN is missing; cannot compare snapshot tags.' >&2; exit 2; }
snapshot_tags="$(awsx rds list-tags-for-resource --resource-name "$snapshot_arn" --query TagList --output json)"
live_primary="$(awsx rds describe-db-instances --db-instance-identifier "$SOURCE_PRIMARY" --query 'DBInstances[0]' --output json)"
[[ "$(jq -r '.DBInstanceStatus' <<<"$live_primary")" == available ]] || { echo 'Source primary is not available.' >&2; exit 2; }
replica_ids="$(jq -c '[.ReadReplicaDBInstanceIdentifiers[]? | split(":") | last]' <<<"$live_primary")"
[[ "$(jq -r 'length' <<<"$replica_ids")" -le 1 ]] || { echo 'Expected at most one source read replica.' >&2; exit 2; }
SOURCE_REPLICA="$(jq -r '.[0] // empty' <<<"$replica_ids")"
if [[ -n "$SOURCE_REPLICA" ]]; then
  live_replica="$(awsx rds describe-db-instances --db-instance-identifier "$SOURCE_REPLICA" --query 'DBInstances[0]' --output json)"
  [[ "$(jq -r '.DBInstanceStatus' <<<"$live_replica")" == available ]] || { echo 'Source replica is not available.' >&2; exit 2; }
  [[ "$(jq -r '.ReadReplicaSourceDBInstanceIdentifier | split(":") | last' <<<"$live_replica")" == "$SOURCE_PRIMARY" ]] \
    || { echo 'Source replica is not attached to the snapshot source primary.' >&2; exit 2; }
else
  live_replica="$live_primary"
fi

BASELINE_STORE="${BB3_RESTORE_BASELINE_DIR:-$HERE/baselines}"
LATEST_CAPTURE="$BASELINE_STORE/latest.json"
[[ -f "$LATEST_CAPTURE" ]] || { echo 'REFUSED: capture a source baseline before restoring.' >&2; exit 2; }
CAPTURE_DIRECTORY_NAME="$(jq -er '.directory | select(test("^[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9]+$"))' "$LATEST_CAPTURE")" \
  || { echo 'REFUSED: latest baseline reference is invalid.' >&2; exit 2; }
CAPTURE_DIRECTORY="$BASELINE_STORE/$CAPTURE_DIRECTORY_NAME"
[[ "$(jq -r '.status' "$LATEST_CAPTURE")" == complete && -f "$CAPTURE_DIRECTORY/manifest.json" ]] \
  || { echo 'REFUSED: latest baseline capture is incomplete.' >&2; exit 2; }
verify_capture_member capture.json || exit 2
cmp -s "$LATEST_CAPTURE" "$CAPTURE_DIRECTORY/capture.json" \
  || { echo 'REFUSED: latest.json does not match the captured metadata file.' >&2; exit 2; }
verify_capture_member primary/baseline.json || exit 2
PRIMARY_BASELINE="$(jq -c . "$CAPTURE_DIRECTORY/primary/baseline.json")"
[[ "$(jq -r '.source' <<<"$PRIMARY_BASELINE")" == "$SOURCE_PRIMARY" \
  && "$(jq -r '.account' <<<"$PRIMARY_BASELINE")" == "$ACCOUNT" \
  && "$(jq -r '.region' <<<"$PRIMARY_BASELINE")" == "$REGION" ]] \
  || { echo 'REFUSED: latest baseline does not match this snapshot source, account, and region.' >&2; exit 2; }
[[ "$(jq -r '.primary' "$LATEST_CAPTURE")" == 'primary/baseline.json' \
  && "$(jq -r '.profile' "$LATEST_CAPTURE")" == "$PROFILE" \
  && "$(jq -r '.region' "$LATEST_CAPTURE")" == "$REGION" ]] \
  || { echo 'REFUSED: latest capture reference does not match this source, account, and region.' >&2; exit 2; }
if [[ -n "$SOURCE_REPLICA" ]]; then
  verify_capture_member replica/baseline.json || exit 2
  REPLICA_BASELINE="$(jq -c . "$CAPTURE_DIRECTORY/replica/baseline.json")"
  [[ "$(jq -r '.source' <<<"$REPLICA_BASELINE")" == "$SOURCE_REPLICA" ]] \
    || { echo 'REFUSED: captured replica does not match the live source topology.' >&2; exit 2; }
else
  [[ "$(jq -r '.replica // ""' "$LATEST_CAPTURE")" == '' ]] \
    || { echo 'REFUSED: latest baseline contains a replica but the live source does not.' >&2; exit 2; }
  REPLICA_BASELINE=''
fi
primary="$(jq -c '.instance' <<<"$PRIMARY_BASELINE")"
if [[ -n "$REPLICA_BASELINE" ]]; then
  replica="$(jq -c '.instance' <<<"$REPLICA_BASELINE")"
else
  replica="$primary"
fi

parameter_summary() {
  local label="$1" instance="$2" groups group name family apply_status values
  groups="$(jq -c '.DBParameterGroups // []' <<<"$instance")"
  [[ "$(jq -r 'length' <<<"$groups")" == 1 ]] || { echo "$label must have exactly one parameter group." >&2; return 1; }
  name="$(jq -r '.[0].DBParameterGroupName' <<<"$groups")"
  apply_status="$(jq -r '.[0].ParameterApplyStatus // "unknown"' <<<"$groups")"
  [[ "$apply_status" == in-sync ]] || { echo "$label parameter group is not in-sync: $apply_status" >&2; return 1; }
  family="$(awsx rds describe-db-parameter-groups --db-parameter-group-name "$name" \
    --query 'DBParameterGroups[0].DBParameterGroupFamily' --output text)"
  values="$(awsx rds describe-db-parameters --db-parameter-group-name "$name" --source user \
    --query 'Parameters[].{Name:ParameterName,Value:ParameterValue}' --output json)"
  printf '%s parameter group: %s (family=%s, apply=%s)\n' "$label" "$name" "$family" "$apply_status" >&2
  if [[ "$(jq -r 'length' <<<"$values")" == 0 ]]; then
    printf '%s user overrides: none\n' "$label" >&2
  else
    printf '%s user overrides (name=value):\n' "$label" >&2
    jq -r '.[] | "  \(.Name)=\(.Value)"' <<<"$values" >&2
  fi
  printf '%s\n' "$name"
}

primary_pg="$(parameter_summary 'Original primary' "$primary")" || exit 2
if [[ -n "$SOURCE_REPLICA" ]]; then
  replica_pg="$(parameter_summary 'Original replica' "$replica")" || exit 2
else
  replica_pg='not present'
  printf '%s\n' 'Original replica: not present in source baseline.' >&2
fi
primary_tags="$(jq -c '.tags' <<<"$PRIMARY_BASELINE")"
if [[ -n "$SOURCE_REPLICA" ]]; then
  replica_tags="$(jq -c '.tags' <<<"$REPLICA_BASELINE")"
else
  replica_tags="$primary_tags"
fi
RUN_ID="DR-$(date -u +%Y%m%d-%H%M)-uat-BB3-S3"
PRIMARY_AZ="$(jq -r '.AvailabilityZone // empty' <<<"$primary")"
REPLICA_AZ=''
if [[ "$(jq -r '.MultiAZ // false' <<<"$primary")" != true ]]; then
  REPLICA_AZ="$(jq -r '.AvailabilityZone // empty' <<<"$replica")"
  if [[ -z "$REPLICA_AZ" || "$REPLICA_AZ" == "$PRIMARY_AZ" ]]; then
    subnet_group="$(jq -r '.DBSubnetGroup.DBSubnetGroupName' <<<"$primary")"
    subnet_azs="$(awsx rds describe-db-subnet-groups --db-subnet-group-name "$subnet_group" \
      --query 'DBSubnetGroups[0].Subnets[].SubnetAvailabilityZone.Name' --output json)"
    REPLICA_AZ="$(jq -er --arg primary_az "$PRIMARY_AZ" '[.[] | select(. != $primary_az)][0]' <<<"$subnet_azs")" \
      || { echo 'No second AZ is available for the new replica.' >&2; exit 2; }
  fi
fi

build_tags() {
  local raw="$1" target="$2" role="$3" from="$4"
  jq -cn --argjson tags "$raw" --arg target "$target" --arg role "$role" --arg run "$RUN_ID" --arg from "$from" "$JQ_LIBRARY"'
    ($tags | userTags | map(if .Key=="Name" then .Value=$target elif .Key=="Role" then .Value=$role else . end))
    + [{Key:"dr-restore",Value:$run},{Key:"dr-restored-from",Value:$from}]
    | reduce .[] as $tag ({}; .[$tag.Key]=$tag.Value) | to_entries | map({Key:.key,Value:.value})'
}

primary_restore_tags="$(build_tags "$primary_tags" "$TARGET_PRIMARY" restore "$SNAPSHOT_ID")"
restore_op="$(jq -nc --arg id "$TARGET_PRIMARY" --arg snapshot "$SNAPSHOT_ID" --argjson source "$primary" \
  '{DBInstanceIdentifier:$id,DBSnapshotIdentifier:$snapshot}
  + (if $source.MultiAZ then {} else {AvailabilityZone:$source.AvailabilityZone} end)')"
restore_request="$(jq -Sc --argjson op "$restore_op" --argjson tags "$primary_restore_tags" \
  "$JQ_LIBRARY"' restore_req($op;$tags)' <<<"$primary")"
restore_model="$(awsx rds restore-db-instance-from-db-snapshot --generate-cli-skeleton input)"
jq -e --argjson model "$restore_model" --argjson source "$primary" --arg pg "$primary_pg" '
  (all(keys[]; . as $key | $model | has($key))) and
  .DBInstanceClass==$source.DBInstanceClass and .DBParameterGroupName==$pg and
  .DBSubnetGroupName==$source.DBSubnetGroup.DBSubnetGroupName and
  ([.VpcSecurityGroupIds[]]|sort)==([$source.VpcSecurityGroups[].VpcSecurityGroupId]|sort) and
  .PubliclyAccessible==false and .BackupRetentionPeriod>=7
' <<<"$restore_request" >/dev/null || { echo 'Restore request failed CLI-model or baseline validation.' >&2; exit 2; }

replica_restore_tags="$(build_tags "$replica_tags" "$TARGET_REPLICA" read-replica "$TARGET_PRIMARY")"
replica_model="$(awsx rds create-db-instance-read-replica --generate-cli-skeleton input)"
replica_request="$(jq -Sc --argjson tags "$replica_restore_tags" --arg id "$TARGET_REPLICA" \
  --arg source "$TARGET_PRIMARY" --arg az "$REPLICA_AZ" --argjson model "$replica_model" "$JQ_LIBRARY"'
  common_req($tags) + {DBInstanceIdentifier:$id,SourceDBInstanceIdentifier:$source,AvailabilityZone:$az}
  | del(.BackupRetentionPeriod,.PreferredBackupWindow,.DBSubnetGroupName,.DBParameterGroupName)
  | with_entries(select(.key as $key | $model | has($key))) | nonnull' <<<"$replica")"
jq -e --argjson model "$replica_model" --argjson source "$replica" \
  --arg id "$TARGET_REPLICA" --arg primary "$TARGET_PRIMARY" --arg az "$REPLICA_AZ" '
  (all(keys[]; . as $key | $model | has($key))) and
  .DBInstanceIdentifier==$id and .SourceDBInstanceIdentifier==$primary and
  .DBInstanceClass==$source.DBInstanceClass and
  (if $az=="" then (has("AvailabilityZone")|not) else .AvailabilityZone==$az end) and
  ([.VpcSecurityGroupIds[]]|sort)==([$source.VpcSecurityGroups[].VpcSecurityGroupId]|sort) and
  .PubliclyAccessible==false and
  (has("DBSubnetGroupName")|not) and (has("DBParameterGroupName")|not) and
  (has("BackupRetentionPeriod")|not) and (has("PreferredBackupWindow")|not)
' <<<"$replica_request" >/dev/null || { echo 'Replica request failed CLI-model or baseline validation.' >&2; exit 2; }

print_request_table() {
  local title="$1" kind="$2" source="$3" request="$4"
  printf '\n%s\n' "$title"
  printf '%-26s | %-34s | %-34s | %s\n' 'API field' 'Original baseline' 'Command value' 'Check'
  printf '%s\n' '---------------------------+------------------------------------+------------------------------------+-----------------'
  jq -nr --arg kind "$kind" --argjson source "$source" --argjson request "$request" '
    def fmt: if .==null then "" elif type=="array" then join(",") else tostring end;
    (if $kind=="primary" then [
      ["DBInstanceIdentifier", null, $request.DBInstanceIdentifier],
      ["DBSnapshotIdentifier", null, $request.DBSnapshotIdentifier],
      ["DBInstanceClass", $source.DBInstanceClass, $request.DBInstanceClass],
      ["AvailabilityZone", $source.AvailabilityZone, $request.AvailabilityZone],
      ["DBParameterGroupName", $source.DBParameterGroups[0].DBParameterGroupName, $request.DBParameterGroupName],
      ["DBSubnetGroupName", $source.DBSubnetGroup.DBSubnetGroupName, $request.DBSubnetGroupName],
      ["VpcSecurityGroupIds", [$source.VpcSecurityGroups[].VpcSecurityGroupId], $request.VpcSecurityGroupIds],
      ["PubliclyAccessible", $source.PubliclyAccessible, $request.PubliclyAccessible],
      ["BackupRetentionPeriod", $source.BackupRetentionPeriod, $request.BackupRetentionPeriod],
      ["PreferredBackupWindow", $source.PreferredBackupWindow, $request.PreferredBackupWindow],
      ["Port", $source.Endpoint.Port, $request.Port],
      ["MultiAZ", $source.MultiAZ, $request.MultiAZ],
      ["DeletionProtection", $source.DeletionProtection, $request.DeletionProtection],
      ["StorageType", $source.StorageType, $request.StorageType],
      ["NetworkType", $source.NetworkType, $request.NetworkType],
      ["CopyTagsToSnapshot", $source.CopyTagsToSnapshot, $request.CopyTagsToSnapshot],
      ["CACertificateIdentifier", $source.CACertificateIdentifier, $request.CACertificateIdentifier],
      ["AutoMinorVersionUpgrade", $source.AutoMinorVersionUpgrade, $request.AutoMinorVersionUpgrade],
      ["EnableIAMDatabaseAuthentication", $source.IAMDatabaseAuthenticationEnabled, $request.EnableIAMDatabaseAuthentication],
      ["EnableCloudwatchLogsExports", $source.EnabledCloudwatchLogsExports, $request.EnableCloudwatchLogsExports]
    ] else [
      ["DBInstanceIdentifier", null, $request.DBInstanceIdentifier],
      ["SourceDBInstanceIdentifier", $source.ReadReplicaSourceDBInstanceIdentifier, $request.SourceDBInstanceIdentifier],
      ["DBInstanceClass", $source.DBInstanceClass, $request.DBInstanceClass],
      ["AvailabilityZone", $source.AvailabilityZone, $request.AvailabilityZone],
      ["VpcSecurityGroupIds", [$source.VpcSecurityGroups[].VpcSecurityGroupId], $request.VpcSecurityGroupIds],
      ["PubliclyAccessible", $source.PubliclyAccessible, $request.PubliclyAccessible],
      ["DeletionProtection", $source.DeletionProtection, $request.DeletionProtection],
      ["CopyTagsToSnapshot", $source.CopyTagsToSnapshot, $request.CopyTagsToSnapshot],
      ["AutoMinorVersionUpgrade", $source.AutoMinorVersionUpgrade, $request.AutoMinorVersionUpgrade],
      ["EnableIAMDatabaseAuthentication", $source.IAMDatabaseAuthenticationEnabled, $request.EnableIAMDatabaseAuthentication],
      ["NetworkType", $source.NetworkType, $request.NetworkType],
      ["Port", $source.Endpoint.Port, $request.Port],
      ["EnableCloudwatchLogsExports", $source.EnabledCloudwatchLogsExports, $request.EnableCloudwatchLogsExports]
    ] end)
    | .[] | select(.[2] != null and .[2] != "" and .[2] != [])
    | [.[0], (.[1]|fmt), (.[2]|fmt),
       (if $kind=="replica" and .[0]=="SourceDBInstanceIdentifier" then "EXPECTED: NEW RESTORE PRIMARY"
        elif .[1]==null then "NEW" elif (.[1]|tojson)==(.[2]|tojson) then "MATCH"
        else "DIFF - REVIEW" end)] | @tsv
  ' | while IFS=$'\t' read -r field original value check; do
    case "$check" in
      MATCH) check="${GREEN}MATCH${RESET}" ;;
      'EXPECTED: NEW RESTORE PRIMARY') check="${GREEN}EXPECTED: NEW RESTORE PRIMARY${RESET}" ;;
      'DIFF - REVIEW') check="${RED}DIFF - REVIEW${RESET}" ;;
    esac
    printf '%-26s | %-34s | %-34s | %s\n' "$field" "${original:-not set}" "$value" "$check"
  done
}

snapshot_diff_rows() {
  jq -nr --argjson baseline "$PRIMARY_BASELINE" --argjson snapshot "$snapshot_record" \
    --argjson snapshot_tags "$snapshot_tags" '
    def tag($items;$key): [$items[]? | select(.Key==$key) | .Value] | first;
    [
      ["Engine", $baseline.instance.Engine, $snapshot.Engine],
      ["EngineVersion", $baseline.instance.EngineVersion, $snapshot.EngineVersion],
      ["Port", $baseline.instance.Endpoint.Port, $snapshot.Port],
      ["AllocatedStorage", $baseline.instance.AllocatedStorage, $snapshot.AllocatedStorage],
      ["StorageEncrypted", $baseline.instance.StorageEncrypted, $snapshot.Encrypted],
      ["KmsKeyId", $baseline.instance.KmsKeyId, $snapshot.KmsKeyId],
      ["VpcId", $baseline.instance.DBSubnetGroup.VpcId, $snapshot.VpcId],
      ["AvailabilityZone", $baseline.instance.AvailabilityZone, $snapshot.AvailabilityZone],
      ["Tag:env", tag($baseline.tags;"env"), tag($snapshot_tags;"env")],
      ["Tag:app", tag($baseline.tags;"app"), tag($snapshot_tags;"app")],
      ["Tag:Role", tag($baseline.tags;"Role"), tag($snapshot_tags;"Role")]
    ]
    | map(select(
        if (.[0]|startswith("Tag:")) then .[1]!=.[2]
        else .[1]!=null and .[2]!=null and (.[1]|tojson)!=(.[2]|tojson)
        end
      ))[]
    | [.[0], (if .[1]==null then "not present" else (.[1]|tostring) end),
       (if .[2]==null then "not present" else (.[2]|tostring) end)] | @tsv
  '
}
SNAPSHOT_DIFFS="$(snapshot_diff_rows)"

print_snapshot_baseline_diffs() {
  local rows="$1" field captured snapshot_value formatted
  if [[ -n "$rows" ]]; then
    printf '\nSnapshot vs captured primary baseline (differences only):\n'
    printf '%-26s | %-38s | %s\n' 'Field' 'Captured primary' 'Selected snapshot'
    printf '%s\n' '---------------------------+----------------------------------------+----------------------------------------'
    while IFS=$'\t' read -r field captured snapshot_value; do
      [[ -n "$field" ]] || continue
      if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
        formatted="$(printf '%-26s | %-38s | %s' "$field" "$captured" "$snapshot_value")"
        printf '%b\n' "${RED}${formatted}${RESET}"
      else
        printf '%-26s | %-38s | %s\n' "$field" "$captured" "$snapshot_value"
      fi
    done <<< "$rows"
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
      printf '%b\n' "${RED}Review each listed difference. The restore is blocked until you type ACCEPT-DIFF.${RESET}"
    else
      printf '%s\n' 'Review each listed difference. The restore is blocked until you type ACCEPT-DIFF.'
    fi
  else
    printf '\nSnapshot metadata/tag comparison: no differences in comparable fields.\n'
  fi
  printf 'Snapshot parameter metadata: not exposed by RDS; restore uses captured source parameter group %s.\n' \
    "$(jq -r '.instance.DBParameterGroups[0].DBParameterGroupName // "not reported"' <<<"$PRIMARY_BASELINE")"
}

confirm_snapshot_diffs() {
  local rows="$1" answer
  [[ -n "$rows" ]] || return 0
  [[ -t 0 && -t 1 ]] || { echo 'Snapshot differences require explicit interactive acceptance.' >&2; exit 2; }
  read -r -p 'Type ACCEPT-DIFF to accept these snapshot differences: ' answer </dev/tty
  [[ "$answer" == ACCEPT-DIFF ]] || { echo 'Cancelled; snapshot differences were not accepted.' >&2; exit 2; }
}

print_primary_confirmation() {
  printf 'Snapshot: %s (source primary: %s)\n' "$SNAPSHOT_ID" "$SOURCE_PRIMARY"
  print_snapshot_baseline_diffs "$SNAPSHOT_DIFFS"
  printf 'Primary parameter group: original=%s; restore request=%s\n' \
    "$primary_pg" "$(jq -r '.DBParameterGroupName' <<<"$restore_request")"
  print_request_table 'Primary restore request (populated fields only)' primary "$primary" "$restore_request"
  printf '\nPost-restore hardening (not sent in snapshot-restore request):\n'
  printf 'PreferredMaintenanceWindow | baseline=%s | apply after restore with ModifyDBInstance\n' \
    "$(jq -r '.PreferredMaintenanceWindow // "not set"' <<<"$primary")"
}

print_replica_confirmation() {
  if [[ -n "$SOURCE_REPLICA" ]]; then
    printf 'Original replica: %s; parameter group=%s\n' "$SOURCE_REPLICA" "$replica_pg"
    print_request_table 'Replica create request (populated fields only)' replica "$replica" "$replica_request"
  else
    printf '%s\n' 'Original replica: not present in source baseline.'
    printf '%s\n' 'New replica request uses the primary baseline; its parameter and subnet groups inherit from the restored primary.'
    print_request_table 'Replica create request (populated fields only)' replica "$primary" "$replica_request"
  fi
  printf 'Expected inherited parameter group: %s\n' "$primary_pg"
  printf 'Expected post-create maintenance window: %s (apply with harden-replica if different)\n' \
    "$(jq -r '.PreferredMaintenanceWindow // "not set"' <<<"$replica")"
}

print_preview() {
  print_primary_confirmation
  print_replica_confirmation
}

build_primary_harden_request() {
  local current="$1" expected_retention
  expected_retention="$(jq -er '[.BackupRetentionPeriod // 0, 7] | max' <<<"$primary")"
  jq -cn --arg id "$TARGET_PRIMARY" --arg group "$primary_pg" \
    --arg backup "$(jq -r '.PreferredBackupWindow // empty' <<<"$primary")" \
    --arg maintenance "$(jq -r '.PreferredMaintenanceWindow // empty' <<<"$primary")" \
    --argjson retention "$expected_retention" --argjson current "$current" '
      {DBInstanceIdentifier:$id}
      + (if $current.DBParameterGroups[0].DBParameterGroupName==$group then {} else {DBParameterGroupName:$group} end)
      + (if $backup=="" or $current.PreferredBackupWindow==$backup then {} else {PreferredBackupWindow:$backup} end)
      + (if $maintenance=="" or $current.PreferredMaintenanceWindow==$maintenance then {} else {PreferredMaintenanceWindow:$maintenance} end)
      + (if $current.BackupRetentionPeriod==$retention then {} else {BackupRetentionPeriod:$retention} end)
      + {ApplyImmediately:true}'
}

build_replica_harden_request() {
  local current="$1" source="$replica"
  [[ -n "$SOURCE_REPLICA" ]] || source="$primary"
  jq -cn --arg id "$TARGET_REPLICA" --arg group "$primary_pg" \
    --arg maintenance "$(jq -r '.PreferredMaintenanceWindow // empty' <<<"$source")" \
    --argjson current "$current" '
      {DBInstanceIdentifier:$id}
      + (if $current.DBParameterGroups[0].DBParameterGroupName==$group then {} else {DBParameterGroupName:$group} end)
      + (if $maintenance=="" or $current.PreferredMaintenanceWindow==$maintenance then {} else {PreferredMaintenanceWindow:$maintenance} end)
      + {ApplyImmediately:true}'
}

print_harden_table() {
  local title="$1" baseline="$2" current="$3" request="$4"
  printf '\n%s\n' "$title"
  printf '%-30s | %-34s | %-34s | %-34s | %s\n' 'Setting' 'Baseline' 'Current' 'Modify request' 'Check'
  printf '%s\n' '-------------------------------+------------------------------------+------------------------------------+------------------------------------+-----------------'
  jq -nr --argjson b "$baseline" --argjson c "$current" --argjson r "$request" '
    def fmt: if .==null then "" elif type=="array" then join(",") else tostring end;
    [["DBParameterGroupName",$b.DBParameterGroups[0].DBParameterGroupName,$c.DBParameterGroups[0].DBParameterGroupName,$r.DBParameterGroupName],
     ["PreferredBackupWindow",$b.PreferredBackupWindow,$c.PreferredBackupWindow,$r.PreferredBackupWindow],
     ["PreferredMaintenanceWindow",$b.PreferredMaintenanceWindow,$c.PreferredMaintenanceWindow,$r.PreferredMaintenanceWindow],
     ["BackupRetentionPeriod",$b.BackupRetentionPeriod,$c.BackupRetentionPeriod,$r.BackupRetentionPeriod]]
    | .[] | select(.[3]!=null)
    | [.[0],(.[1]|fmt),(.[2]|fmt),(.[3]|fmt),"DIFF - REVIEW"] | @tsv
  ' | while IFS=$'\t' read -r field baseline_value current_value request_value check; do
    printf '%-30s | %-34s | %-34s | %-34s | %s%s%s\n' \
      "$field" "${baseline_value:-not set}" "${current_value:-not set}" "$request_value" "$RED" "$check" "$RESET"
  done
}

validate_modify_model() {
  local request="$1" model="$2"
  jq -e --argjson model "$model" '
    all(keys[]; . as $key | $model | has($key)) and
    ([keys[]|select(.!="DBInstanceIdentifier" and .!="ApplyImmediately")]|length)>0
  ' <<<"$request" >/dev/null
}

require_absent() {
  local id="$1" all
  all="$(awsx rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier' --output json)"
  jq -e --arg id "$id" 'index($id)==null' <<<"$all" >/dev/null || { echo "Target already exists: $id" >&2; exit 2; }
}

confirm() {
  local action="$1" answer
  [[ -t 0 && -t 1 ]] || { echo 'Confirmation requires an interactive terminal.' >&2; exit 2; }
  read -r -p "Submit $action? [y/N]: " answer </dev/tty
  case "${answer,,}" in
    y|yes) ;;
    *) echo 'Cancelled; no RDS request was submitted.' >&2; exit 2 ;;
  esac
}

case "$MODE" in
  preview)
    print_preview
    ;;
  status)
    ;;
  restore)
    require_absent "$TARGET_PRIMARY"
    require_absent "$TARGET_REPLICA"
    print_primary_confirmation
    confirm_snapshot_diffs "$SNAPSHOT_DIFFS"
    confirm RESTORE
    umask 077
    request_file="$(mktemp "${TMPDIR:-/tmp}/bb3-restore-request.XXXXXX")"
    trap 'rm -f "$request_file"' EXIT
    printf '%s\n' "$restore_request" > "$request_file"
    awsx rds restore-db-instance-from-db-snapshot --cli-input-json "file://$request_file" \
      --query 'DBInstance.[DBInstanceStatus,DBInstanceClass,PubliclyAccessible,BackupRetentionPeriod]' --output text
    printf 'Primary restore started. After it is available, harden/check its parameter group with:\n'
    printf '%s\n' 'bash iac/lab/bb3-db/restore-drill.sh harden-primary'
    printf 'Then create the replica with:\n'
    printf '%s\n' 'bash iac/lab/bb3-db/restore-drill.sh replica'
    ;;
  harden-primary)
    restored_primary="$(awsx rds describe-db-instances --db-instance-identifier "$TARGET_PRIMARY" --query 'DBInstances[0]' --output json)"
    [[ "$(jq -r '.DBInstanceStatus' <<<"$restored_primary")" == available ]] \
      || { echo 'Restored primary must be available before parameter-group hardening.' >&2; exit 2; }
    harden_request="$(build_primary_harden_request "$restored_primary")"
    if [[ "$(jq -r 'keys|length' <<<"$harden_request")" == 2 ]]; then
      printf '%s\n' 'Restored primary backup window, maintenance window, retention and parameter group match the baseline; no modify request needed.'
      exit 0
    fi
    modify_model="$(awsx rds modify-db-instance --generate-cli-skeleton input)"
    validate_modify_model "$harden_request" "$modify_model" || { echo 'Primary hardening request contains an unsupported API field.' >&2; exit 2; }
    print_harden_table 'Primary post-restore hardening (baseline vs current vs ModifyDBInstance)' "$primary" "$restored_primary" "$harden_request"
    confirm APPLY-PARAMETER-GROUP
    request_file="$(mktemp "${TMPDIR:-/tmp}/bb3-primary-harden.XXXXXX")"
    trap 'rm -f "$request_file"' EXIT
    printf '%s\n' "$harden_request" > "$request_file"
    awsx rds modify-db-instance --cli-input-json "file://$request_file" \
      --query 'DBInstance.[DBInstanceStatus,DBParameterGroups[0].DBParameterGroupName,DBParameterGroups[0].ParameterApplyStatus,PreferredBackupWindow,PreferredMaintenanceWindow,BackupRetentionPeriod]' \
      --output text
    ;;
  replica)
    restored_primary="$(awsx rds describe-db-instances --db-instance-identifier "$TARGET_PRIMARY" --query 'DBInstances[0]' --output json)"
    [[ "$(jq -r '.DBInstanceStatus' <<<"$restored_primary")" == available ]] \
      || { echo 'Restored primary must be available before replica creation.' >&2; exit 2; }
    [[ "$(jq -r '.ReadReplicaSourceDBInstanceIdentifier // ""' <<<"$restored_primary")" == "" ]] \
      || { echo 'Target primary is itself a read replica.' >&2; exit 2; }
    restored_pg="$(jq -er '.DBParameterGroups[0].DBParameterGroupName' <<<"$restored_primary")"
    restored_pg_status="$(jq -r '.DBParameterGroups[0].ParameterApplyStatus // "unknown"' <<<"$restored_primary")"
    [[ "$restored_pg" == "$primary_pg" && "$restored_pg_status" == in-sync ]] \
      || { echo 'Restored primary must use the captured parameter group in-sync; run harden-primary first.' >&2; exit 2; }
    [[ "$(jq -r '.BackupRetentionPeriod' <<<"$restored_primary")" == "$(jq -r '([.BackupRetentionPeriod // 0,7]|max)' <<<"$primary")" ]] \
      || { echo 'Restored primary backup retention differs from baseline; run harden-primary first.' >&2; exit 2; }
    [[ "$(jq -r '.PreferredBackupWindow' <<<"$restored_primary")" == "$(jq -r '.PreferredBackupWindow' <<<"$primary")" ]] \
      || { echo 'Restored primary backup window differs from baseline; run harden-primary first.' >&2; exit 2; }
    [[ "$(jq -r '.PreferredMaintenanceWindow' <<<"$restored_primary")" == "$(jq -r '.PreferredMaintenanceWindow' <<<"$primary")" ]] \
      || { echo 'Restored primary maintenance window differs from baseline; run harden-primary first.' >&2; exit 2; }
    [[ "$(jq -r '.DBSubnetGroup.DBSubnetGroupName' <<<"$restored_primary")" == "$(jq -r '.DBSubnetGroup.DBSubnetGroupName' <<<"$primary")" ]] \
      || { echo 'Restored primary subnet group does not match the captured baseline.' >&2; exit 2; }
    [[ "$(jq -r '[.VpcSecurityGroups[].VpcSecurityGroupId]|sort|join(",")' <<<"$restored_primary")" == \
       "$(jq -r '[.VpcSecurityGroups[].VpcSecurityGroupId]|sort|join(",")' <<<"$primary")" ]] \
      || { echo 'Restored primary security groups do not match the captured baseline.' >&2; exit 2; }
    [[ "$(jq -r '.PubliclyAccessible' <<<"$restored_primary")" == false ]] \
      || { echo 'Restored primary is publicly accessible; refusing replica creation.' >&2; exit 2; }
    require_absent "$TARGET_REPLICA"
    print_replica_confirmation
    confirm CREATE-REPLICA
    umask 077
    request_file="$(mktemp "${TMPDIR:-/tmp}/bb3-replica-request.XXXXXX")"
    trap 'rm -f "$request_file"' EXIT
    printf '%s\n' "$replica_request" > "$request_file"
    awsx rds create-db-instance-read-replica --cli-input-json "file://$request_file" \
      --query 'DBInstance.[DBInstanceStatus,DBInstanceClass,PubliclyAccessible,DBSubnetGroup.DBSubnetGroupName]' --output text
    printf 'After replica availability, compare/apply its maintenance and parameter settings with:\n'
    printf '%s\n' 'bash iac/lab/bb3-db/restore-drill.sh harden-replica'
    ;;
  harden-replica)
    restored_replica="$(awsx rds describe-db-instances --db-instance-identifier "$TARGET_REPLICA" --query 'DBInstances[0]' --output json)"
    [[ "$(jq -r '.DBInstanceStatus' <<<"$restored_replica")" == available ]] \
      || { echo 'Restored replica must be available before hardening.' >&2; exit 2; }
    restored_primary="$(awsx rds describe-db-instances --db-instance-identifier "$TARGET_PRIMARY" --query 'DBInstances[0]' --output json)"
    [[ "$(jq -r '.ReadReplicaSourceDBInstanceIdentifier | split(":") | last' <<<"$restored_replica")" == "$TARGET_PRIMARY" ]] \
      || { echo 'Target replica is not attached to the requested restored primary.' >&2; exit 2; }
    [[ "$(jq -r '.DBSubnetGroup.DBSubnetGroupName' <<<"$restored_replica")" == "$(jq -r '.DBSubnetGroup.DBSubnetGroupName' <<<"$restored_primary")" ]] \
      || { echo 'Restored replica subnet group differs from the restored primary.' >&2; exit 2; }
    [[ "$(jq -r '[.VpcSecurityGroups[].VpcSecurityGroupId]|sort|join(",")' <<<"$restored_replica")" == \
       "$(jq -r '[.VpcSecurityGroups[].VpcSecurityGroupId]|sort|join(",")' <<<"$restored_primary")" ]] \
      || { echo 'Restored replica security groups differ from the restored primary.' >&2; exit 2; }
    expected_replica_source="$replica"; [[ -n "$SOURCE_REPLICA" ]] || expected_replica_source="$primary"
    expected_replica_pg="$(jq -er '.DBParameterGroups[0].DBParameterGroupName' <<<"$expected_replica_source")"
    current_replica_pg="$(jq -er '.DBParameterGroups[0].DBParameterGroupName' <<<"$restored_replica")"
    current_replica_pg_status="$(jq -r '.DBParameterGroups[0].ParameterApplyStatus // "unknown"' <<<"$restored_replica")"
    replica_harden_request="$(build_replica_harden_request "$restored_replica")"
    if [[ "$(jq -r 'keys|length' <<<"$replica_harden_request")" == 2 && "$current_replica_pg" == "$expected_replica_pg" && "$current_replica_pg_status" == in-sync ]]; then
      printf 'Replica parameter group and maintenance window match baseline and are in-sync; no modify request needed.\n'
      exit 0
    fi
    modify_model="$(awsx rds modify-db-instance --generate-cli-skeleton input)"
    validate_modify_model "$replica_harden_request" "$modify_model" || { echo 'Replica hardening request contains an unsupported API field.' >&2; exit 2; }
    print_harden_table 'Replica post-create hardening (baseline vs current vs ModifyDBInstance)' "$expected_replica_source" "$restored_replica" "$replica_harden_request"
    printf 'Parameter apply status: %s\n' "$current_replica_pg_status"
    confirm APPLY-REPLICA-HARDEN
    request_file="$(mktemp "${TMPDIR:-/tmp}/bb3-replica-harden.XXXXXX")"
    trap 'rm -f "$request_file"' EXIT
    printf '%s\n' "$replica_harden_request" > "$request_file"
    awsx rds modify-db-instance --cli-input-json "file://$request_file" \
      --query 'DBInstance.[DBInstanceStatus,DBParameterGroups[0].DBParameterGroupName,DBParameterGroups[0].ParameterApplyStatus,PreferredMaintenanceWindow]' \
      --output text
    ;;
esac