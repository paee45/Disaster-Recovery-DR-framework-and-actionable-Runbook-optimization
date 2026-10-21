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
PARAMETER_TEMP_DIR=''
cleanup() {
  [[ -z "$PARAMETER_TEMP_DIR" ]] || rm -rf "$PARAMETER_TEMP_DIR"
  [[ -z "${request_file:-}" ]] || rm -f "$request_file"
}
CALLER_ACCOUNT="$(awsx sts get-caller-identity --query Account --output text)"
[[ "$CALLER_ACCOUNT" == "$ACCOUNT" ]] || { echo 'AWS caller does not match the configured sandbox account.' >&2; exit 2; }
PARAMETER_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bb3-parameter-check.XXXXXX")"
trap cleanup EXIT

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
verify_capture_member primary/parameters-1.json || exit 2
awsx rds describe-db-parameters --db-parameter-group-name "$primary_pg" --output json \
  > "$PARAMETER_TEMP_DIR/primary.json"
jq -e '.Parameters | type=="array"' "$PARAMETER_TEMP_DIR/primary.json" >/dev/null \
  || { echo 'Current primary parameter API response is invalid.' >&2; exit 2; }
primary_tags="$(jq -c '.tags' <<<"$PRIMARY_BASELINE")"
if [[ -n "$SOURCE_REPLICA" ]]; then
  replica_tags="$(jq -c '.tags' <<<"$REPLICA_BASELINE")"
else
  replica_tags="$primary_tags"
fi
snapshot_tag_diff_rows() {
  jq -nr --argjson baseline "$primary_tags" --argjson snapshot "$snapshot_tags" '
    def tags_by_key: reduce .[]? as $tag ({}; .[$tag.Key]=$tag.Value);
    ($baseline | map(select((.Key|startswith("aws:"))|not)) | tags_by_key) as $base |
    ($snapshot | map(select((.Key|startswith("aws:"))|not)) | tags_by_key) as $snap |
    ((($base|keys)+($snap|keys))|unique[]) as $key |
    select($key!="Name" and $key!="Role" and $key!="dr-restore" and $key!="dr-restored-from") |
    ($base[$key] // null) as $old |
    ($snap[$key] // null) as $new |
    select($old!=$new) |
    [$key,(if $old==null then "not present" else $old end),(if $new==null then "not present" else $new end)] | @tsv
  '
}
SNAPSHOT_TAG_DIFFS="$(snapshot_tag_diff_rows)"
RESTORE_TAG_DECISIONS=()
RESTORE_TAG_DECISIONS_JSON='{}'
print_snapshot_tag_choice_table() {
  local tag_key baseline_value snapshot_value old_cell snapshot_cell
  [[ -n "$SNAPSHOT_TAG_DIFFS" ]] || return 0
  printf '\nSnapshot tag differences (one choice at a time; option 1 is the default):\n'
  printf '%-24s | %-34s | %s\n' 'Tag' 'Captured primary [1]' 'Selected snapshot [2]'
  printf '%s\n' '-------------------------+------------------------------------+------------------------------------'
  while IFS=$'\t' read -r tag_key baseline_value snapshot_value; do
    [[ -n "$tag_key" ]] || continue
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
      old_cell="$(printf '%-34s' "$baseline_value (default)")"
      snapshot_cell="$(printf '%s' "$snapshot_value")"
      printf '%-24s | %b | %b\n' "$tag_key" "${GREEN}${old_cell}${RESET}" "${RED}${snapshot_cell}${RESET}"
    else
      printf '%-24s | %-34s | %s\n' "$tag_key" "$baseline_value (default)" "$snapshot_value"
    fi
  done <<< "$SNAPSHOT_TAG_DIFFS"
}
if [[ "$MODE" == restore && -n "$SNAPSHOT_TAG_DIFFS" ]]; then
  [[ -t 0 && -t 1 ]] || { echo 'Snapshot tag differences require interactive per-tag choices.' >&2; exit 2; }
  while IFS=$'\t' read -r tag_key baseline_value snapshot_value; do
    [[ -n "$tag_key" ]] || continue
    printf '\nTag %s\n' "$tag_key"
    printf '%-24s | %-34s | %s\n' 'Tag' 'Captured primary [1]' 'Selected snapshot [2]'
    printf '%s\n' '-------------------------+------------------------------------+------------------------------------'
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
      old_cell="$(printf '%-34s' "$baseline_value (default)")"
      printf '%-24s | %b | %b\n' "$tag_key" "${GREEN}${old_cell}${RESET}" "${RED}${snapshot_value}${RESET}"
    else
      printf '%-24s | %-34s | %s\n' "$tag_key" "$baseline_value (default)" "$snapshot_value"
    fi
    tag_prompt="Choose '$tag_key' [1/2, default 1: $baseline_value]"
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
      tag_prompt="Choose '$tag_key' [1/2, default 1: ${GREEN}${baseline_value}${RESET}]"
    fi
    read -r -p "$tag_prompt: " tag_choice </dev/tty
    tag_choice="${tag_choice:-1}"
    [[ "$tag_choice" == 1 || "$tag_choice" == 2 ]] || { echo 'A tag choice of 1 or 2 is required; no restore was submitted.' >&2; exit 2; }
    selected_tag_value="$baseline_value"; [[ "$tag_choice" == 2 ]] && selected_tag_value="$snapshot_value"
    if [[ "$selected_tag_value" == 'not present' ]]; then
      primary_tags="$(jq -cn --argjson tags "$primary_tags" --arg key "$tag_key" '$tags|map(select(.Key!=$key))')"
    else
      primary_tags="$(jq -cn --argjson tags "$primary_tags" --arg key "$tag_key" --arg value "$selected_tag_value" '
        if any($tags[]?;.Key==$key) then $tags|map(if .Key==$key then .Value=$value else . end)
        else $tags+[{Key:$key,Value:$value}] end
      ')"
    fi
    RESTORE_TAG_DECISIONS+=("$tag_key=$selected_tag_value")
    RESTORE_TAG_DECISIONS_JSON="$(jq -cn --argjson choices "$RESTORE_TAG_DECISIONS_JSON" --arg key "$tag_key" --arg value "$selected_tag_value" \
      'if $value=="not present" then $choices + {($key):null} else $choices + {($key):$value} end')"
  done <<< "$SNAPSHOT_TAG_DIFFS"
  replica_tags="$(jq -cn --argjson tags "$replica_tags" --argjson choices "$RESTORE_TAG_DECISIONS_JSON" '
    reduce ($choices|to_entries[]) as $entry ($tags;
      if $entry.value==null then map(select(.Key!=$entry.key))
      elif any(.[]?;.Key==$entry.key) then map(if .Key==$entry.key then .Value=$entry.value else . end)
      else .+[{Key:$entry.key,Value:$entry.value}] end
    )
  ')"
fi
RUN_ID="${BB3_DR_ID:-DR-$(date -u +%Y%m%d-%H%M)-uat-BB3-S3}"
[[ "$RUN_ID" =~ ^DR-[A-Za-z0-9_-]{1,120}$ ]] || { echo 'Invalid BB3_DR_ID in sandbox config.' >&2; exit 2; }
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

primary_restore_tags="$(build_tags "$primary_tags" "$TARGET_PRIMARY" primary "$SNAPSHOT_ID")"
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
  --arg source "$TARGET_PRIMARY" --arg az "$REPLICA_AZ" --argjson model "$replica_model" \
  --argjson primary "$primary" "$JQ_LIBRARY"'
  common_req($tags) + {VpcSecurityGroupIds:[$primary.VpcSecurityGroups[].VpcSecurityGroupId],
    DBInstanceIdentifier:$id,SourceDBInstanceIdentifier:$source,AvailabilityZone:$az}
  | del(.BackupRetentionPeriod,.PreferredBackupWindow,.DBSubnetGroupName,.DBParameterGroupName)
  | with_entries(select(.key as $key | $model | has($key))) | nonnull' <<<"$replica")"
jq -e --argjson model "$replica_model" --argjson source "$replica" --argjson primary "$primary" \
  --arg id "$TARGET_REPLICA" --arg primary_id "$TARGET_PRIMARY" --arg az "$REPLICA_AZ" '
  (all(keys[]; . as $key | $model | has($key))) and
  .DBInstanceIdentifier==$id and .SourceDBInstanceIdentifier==$primary_id and
  .DBInstanceClass==$source.DBInstanceClass and
  (if $az=="" then (has("AvailabilityZone")|not) else .AvailabilityZone==$az end) and
  ([.VpcSecurityGroupIds[]]|sort)==([$primary.VpcSecurityGroups[].VpcSecurityGroupId]|sort) and
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
       elif $kind=="replica" and .[0]=="VpcSecurityGroupIds" then "EXPECTED: RESTORED PRIMARY SG SET"
        elif .[1]==null then "NEW" elif (.[1]|tojson)==(.[2]|tojson) then "MATCH"
        else "DIFF - REVIEW" end)] | @tsv
  ' | while IFS=$'\t' read -r field original value check; do
    case "$check" in
      MATCH) check="${GREEN}MATCH${RESET}" ;;
      'EXPECTED: NEW RESTORE PRIMARY') check="${GREEN}EXPECTED: NEW RESTORE PRIMARY${RESET}" ;;
      'EXPECTED: RESTORED PRIMARY SG SET') check="${GREEN}EXPECTED: RESTORED PRIMARY SG SET${RESET}" ;;
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
      ["ENGINE", "Engine", $baseline.instance.Engine, $snapshot.Engine],
      ["ENGINE", "EngineVersion", $baseline.instance.EngineVersion, $snapshot.EngineVersion],
      ["ENGINE", "LicenseModel", $baseline.instance.LicenseModel, $snapshot.LicenseModel],
      ["ENGINE", "OptionGroupName", $baseline.instance.OptionGroupMemberships[0].OptionGroupName, $snapshot.OptionGroupName],
      ["NETWORK", "Port", $baseline.instance.Endpoint.Port, $snapshot.Port],
      ["NETWORK", "VpcId", $baseline.instance.DBSubnetGroup.VpcId, $snapshot.VpcId],
      ["NETWORK", "AvailabilityZone", $baseline.instance.AvailabilityZone, $snapshot.AvailabilityZone],
      ["STORAGE", "AllocatedStorage", $baseline.instance.AllocatedStorage, $snapshot.AllocatedStorage],
      ["STORAGE", "StorageType", $baseline.instance.StorageType, $snapshot.StorageType],
      ["STORAGE", "Iops", $baseline.instance.Iops, $snapshot.Iops],
      ["SECURITY", "StorageEncrypted", $baseline.instance.StorageEncrypted, $snapshot.Encrypted],
      ["SECURITY", "KmsKeyId", $baseline.instance.KmsKeyId, $snapshot.KmsKeyId]
    ]
    | map(select(
        .[2]!=null and .[3]!=null and (.[2]|tojson)!=(.[3]|tojson)
      ))[]
    | [.[0], .[1], (.[2]|tostring), (.[3]|tostring)] | @tsv
  '
}
SNAPSHOT_DIFFS="$(snapshot_diff_rows)"

parameter_diff_rows() {
  local captured_file="$1" current_file="$2"
  jq -nr --slurpfile captured "$captured_file" --slurpfile current "$current_file" '
    def by_name: reduce .Parameters[] as $parameter ({}; .[$parameter.ParameterName]=$parameter);
    def fmt($parameter): if $parameter==null then "not present"
      else "\($parameter.ParameterValue // "not set") [\($parameter.Source // "unknown")]" end;
    ($captured[0]|by_name) as $baseline |
    ($current[0]|by_name) as $live |
    ((($baseline|keys)+($live|keys))|unique[]) as $name |
    ($baseline[$name] // null) as $old |
    ($live[$name] // null) as $new |
    select($old!=$new) |
    ([((($old // {})|keys[]),(($new // {})|keys[]))] | unique |
      map(. as $field | select(($old // {})[$field] != ($new // {})[$field]))) as $changed |
    [$name,fmt($old),fmt($new),($changed|join(","))] | @tsv
  '
}
PRIMARY_PARAMETER_DIFFS="$(parameter_diff_rows "$CAPTURE_DIRECTORY/primary/parameters-1.json" "$PARAMETER_TEMP_DIR/primary.json")"
PRIMARY_PARAMETER_COUNT="$(jq -r '.Parameters|length' "$CAPTURE_DIRECTORY/primary/parameters-1.json")"
PRIMARY_LIVE_PARAMETER_COUNT="$(jq -r '.Parameters|length' "$PARAMETER_TEMP_DIR/primary.json")"
REPLICA_PARAMETER_DIFFS=''; REPLICA_PARAMETER_COUNT=0; REPLICA_LIVE_PARAMETER_COUNT=0

print_snapshot_baseline_diffs() {
  local rows="$1" diff_type field captured snapshot_value formatted
  if [[ -n "$rows" ]]; then
    printf '\nSnapshot vs captured primary baseline (differences only):\n'
    printf '%-10s | %-26s | %-38s | %s\n' 'Diff type' 'Field' 'Captured primary' 'Selected snapshot'
    printf '%s\n' '-----------+---------------------------+----------------------------------------+----------------------------------------'
    while IFS=$'\t' read -r diff_type field captured snapshot_value; do
      [[ -n "$field" ]] || continue
      if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
        formatted="$(printf '%-10s | %-26s | %-38s | %s' "$diff_type" "$field" "$captured" "$snapshot_value")"
        printf '%b\n' "${RED}${formatted}${RESET}"
      else
        printf '%-10s | %-26s | %-38s | %s\n' "$diff_type" "$field" "$captured" "$snapshot_value"
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
  [[ -t 0 && -t 1 ]] || { echo 'Snapshot metadata/tag differences require explicit interactive acceptance.' >&2; exit 2; }
  read -r -p 'Type ACCEPT-DIFF to accept snapshot metadata/tag differences: ' answer </dev/tty
  [[ "$answer" == ACCEPT-DIFF ]] || { echo 'Cancelled; snapshot differences were not accepted.' >&2; exit 2; }
}

confirm_current_parameters() {
  local answer
  [[ -n "$PRIMARY_PARAMETER_DIFFS" ]] || return 0
  printf 'Parameter values differ from the captured primary. The snapshot has no parameter-value list.\n'
  printf 'The restore request uses parameter group %s, with its current AWS values.\n' "$primary_pg"
  printf '%s\n' 'To use the historical captured values instead, cancel and provision an approved parameter group; this helper will not rebuild it.'
  [[ -t 0 && -t 1 ]] || { echo 'Parameter drift requires an explicit current-group choice or cancellation.' >&2; exit 2; }
  read -r -p 'Type USE-CURRENT-PARAMETERS to continue with this group: ' answer </dev/tty
  [[ "$answer" == USE-CURRENT-PARAMETERS ]] \
    || { echo 'Cancelled; parameter values were not selected.' >&2; exit 2; }
}

print_parameter_diffs() {
  local role="$1" rows="$2" captured_count="$3" live_count="$4"
  if [[ -z "$rows" ]]; then
    printf '%s parameters: %s captured / %s live API records; no differences (MATCH).\n' \
      "$role" "$captured_count" "$live_count"
    return
  fi
  printf '\n%s captured vs live parameter API (differences only):\n' "$role"
  printf '%-34s | %-36s | %-36s | %s\n' 'Parameter' 'Captured value [source]' 'Live value [source]' 'Changed API fields'
  printf '%s\n' '-----------------------------------+--------------------------------------+--------------------------------------+--------------------'
  while IFS=$'\t' read -r name captured live changed; do
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
      formatted="$(printf '%-34s | %-36s | %-36s | %s' "$name" "$captured" "$live" "$changed")"
      printf '%b\n' "${RED}${formatted}${RESET}"
    else
      printf '%-34s | %-36s | %-36s | %s\n' "$name" "$captured" "$live" "$changed"
    fi
  done <<< "$rows"
  printf '%s parameters: %s captured / %s live API records; review differences.\n' \
    "$role" "$captured_count" "$live_count"
}

print_primary_confirmation() {
  printf 'Snapshot: %s (source primary: %s)\n' "$SNAPSHOT_ID" "$SOURCE_PRIMARY"
  print_snapshot_baseline_diffs "$SNAPSHOT_DIFFS"
  [[ "$MODE" == restore ]] || print_snapshot_tag_choice_table
  if [[ -n "$SNAPSHOT_TAG_DIFFS" ]]; then
    printf '\nSnapshot tag decisions (Name/Role are assigned to the new target automatically):\n'
    if [[ ${#RESTORE_TAG_DECISIONS[@]} -gt 0 ]]; then
      printf 'Selected tag values: %s\n' "${RESTORE_TAG_DECISIONS[*]}"
    else
      while IFS=$'\t' read -r tag_key baseline_value snapshot_value; do
        printf '  %s: captured primary=%s | snapshot=%s | restore choices: 1=primary, 2=snapshot\n' \
          "$tag_key" "$baseline_value" "$snapshot_value"
      done <<< "$SNAPSHOT_TAG_DIFFS"
    fi
  fi
  print_parameter_diffs primary "$PRIMARY_PARAMETER_DIFFS" "$PRIMARY_PARAMETER_COUNT" "$PRIMARY_LIVE_PARAMETER_COUNT"
  printf 'Primary parameter group: original=%s; restore request=%s\n' \
    "$primary_pg" "$(jq -r '.DBParameterGroupName' <<<"$restore_request")"
  printf 'Restore tags (after per-tag choices):\n'
  jq -r '.Tags[]? | "  \(.Key)=\(.Value)"' <<<"$restore_request"
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
  jq -cn --arg id "$TARGET_REPLICA" --arg group "$expected_replica_pg" \
    --arg maintenance "$(jq -r '.PreferredMaintenanceWindow // empty' <<<"$source")" \
    --argjson current "$current" --argjson primary "$restored_primary" '
      {DBInstanceIdentifier:$id}
      + (if $current.DBParameterGroups[0].DBParameterGroupName==$group then {} else {DBParameterGroupName:$group} end)
      + (if ([$current.VpcSecurityGroups[].VpcSecurityGroupId]|sort)==([$primary.VpcSecurityGroups[].VpcSecurityGroupId]|sort)
         then {} else {VpcSecurityGroupIds:[$primary.VpcSecurityGroups[].VpcSecurityGroupId]} end)
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
      ["VpcSecurityGroupIds",[$b.VpcSecurityGroups[].VpcSecurityGroupId],[$c.VpcSecurityGroups[].VpcSecurityGroupId],$r.VpcSecurityGroupIds],
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

confirm_go() {
  local answer
  [[ -t 0 && -t 1 ]] || { echo 'Explicit IC/data-owner GO gate requires an interactive terminal.' >&2; exit 2; }
  read -r -p 'Type GO after data-owner loss acceptance and IC approval: ' answer </dev/tty
  [[ "$answer" == GO ]] || { echo 'Cancelled; restore was not submitted.' >&2; exit 2; }
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
    confirm_current_parameters
    confirm_go
    confirm RESTORE
    umask 077
    request_file="$(mktemp "${TMPDIR:-/tmp}/bb3-restore-request.XXXXXX")"
    trap cleanup EXIT
    printf '%s\n' "$restore_request" > "$request_file"
    printf 'AWS command: aws --profile %s --region %s --no-cli-pager rds restore-db-instance-from-db-snapshot --cli-input-json file://%s\n' \
      "$PROFILE" "$REGION" "$request_file"
    restore_result="$(awsx rds restore-db-instance-from-db-snapshot --cli-input-json "file://$request_file" \
      --query 'DBInstance.[DBInstanceStatus,DBInstanceClass,PubliclyAccessible,BackupRetentionPeriod]' --output text
    )"
    printf 'AWS result (status, class, public, retention): %s\n' "$restore_result"
    printf '%s\n' 'Next in all-in-one mode: P2-S02 waits for availability, then P2-S03 validates/hardens.'
    printf 'Selected-step commands: bash iac/lab/bb3-db/bb3-run.sh S3 --only P2-S02\n'
    printf 'Then: bash iac/lab/bb3-db/bb3-run.sh S3 --only P2-S03\n'
    printf 'Create the replica later with: bash iac/lab/bb3-db/bb3-run.sh S3 --only P2-S05\n'
    ;;
  harden-primary)
    restored_primary="$(awsx rds describe-db-instances --db-instance-identifier "$TARGET_PRIMARY" --query 'DBInstances[0]' --output json)"
    [[ "$(jq -r '.DBInstanceStatus' <<<"$restored_primary")" == available ]] \
      || { echo 'Restored primary must be available before parameter-group hardening.' >&2; exit 2; }
    restored_primary_pg="$(jq -er '.DBParameterGroups[0].DBParameterGroupName' <<<"$restored_primary")"
    awsx rds describe-db-parameters --db-parameter-group-name "$restored_primary_pg" --output json \
      > "$PARAMETER_TEMP_DIR/restored-primary.json"
    jq -e '.Parameters|type=="array"' "$PARAMETER_TEMP_DIR/restored-primary.json" >/dev/null \
      || { echo 'Restored primary parameter API response is invalid.' >&2; exit 2; }
    restored_primary_parameter_diffs="$(parameter_diff_rows "$CAPTURE_DIRECTORY/primary/parameters-1.json" "$PARAMETER_TEMP_DIR/restored-primary.json")"
    restored_primary_parameter_count="$(jq -r '.Parameters|length' "$CAPTURE_DIRECTORY/primary/parameters-1.json")"
    restored_primary_live_count="$(jq -r '.Parameters|length' "$PARAMETER_TEMP_DIR/restored-primary.json")"
    print_parameter_diffs 'Restored primary vs captured original primary' "$restored_primary_parameter_diffs" \
      "$restored_primary_parameter_count" "$restored_primary_live_count"
    if [[ -n "$restored_primary_parameter_diffs" && "$restored_primary_pg" == "$primary_pg" ]]; then
      echo 'REFUSED: restored primary uses the expected group but its full parameter API differs from the captured primary. Review the parameter group; this helper cannot reconstruct historical group contents.' >&2
      exit 2
    fi
    harden_request="$(build_primary_harden_request "$restored_primary")"
    if [[ "$(jq -r 'keys|length' <<<"$harden_request")" == 2 ]]; then
      [[ -z "$restored_primary_parameter_diffs" ]] \
        || { echo 'REFUSED: restored primary parameter values still differ from the captured primary.' >&2; exit 2; }
      printf '%s\n' 'Restored primary backup window, maintenance window, retention and parameter group match the baseline; no modify request needed.'
      exit 0
    fi
    modify_model="$(awsx rds modify-db-instance --generate-cli-skeleton input)"
    validate_modify_model "$harden_request" "$modify_model" || { echo 'Primary hardening request contains an unsupported API field.' >&2; exit 2; }
    print_harden_table 'Primary post-restore hardening (baseline vs current vs ModifyDBInstance)' "$primary" "$restored_primary" "$harden_request"
    confirm APPLY-PARAMETER-GROUP
    request_file="$(mktemp "${TMPDIR:-/tmp}/bb3-primary-harden.XXXXXX")"
    trap cleanup EXIT
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
    trap cleanup EXIT
    printf '%s\n' "$replica_request" > "$request_file"
    printf 'AWS command running: aws --profile %s --region %s --no-cli-pager rds create-db-instance-read-replica --cli-input-json file://%s\n' \
      "$PROFILE" "$REGION" "$request_file"
    jq -r '
      "  DBInstanceIdentifier: \(.DBInstanceIdentifier)",
      "  SourceDBInstanceIdentifier: \(.SourceDBInstanceIdentifier)",
      "  DBInstanceClass: \(.DBInstanceClass)",
      "  AvailabilityZone: \(.AvailabilityZone)",
      "  VpcSecurityGroupIds: \(.VpcSecurityGroupIds|join(","))",
      "  PubliclyAccessible: \(.PubliclyAccessible)"
    ' "$request_file"
    awsx rds create-db-instance-read-replica --cli-input-json "file://$request_file" \
      --query 'DBInstance.[DBInstanceStatus,DBInstanceClass,PubliclyAccessible,DBSubnetGroup.DBSubnetGroupName]' --output text
    printf '%s\n' 'In all-in-one mode, P2-S06 waits for availability; P2-S07 validates/hardens the replica.'
    printf 'Selected-step commands: bash iac/lab/bb3-db/bb3-run.sh S3 --only P2-S06\n'
    printf 'Then: bash iac/lab/bb3-db/bb3-run.sh S3 --only P2-S07\n'
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
    expected_replica_source="$replica"; [[ -n "$SOURCE_REPLICA" ]] || expected_replica_source="$primary"
    expected_replica_pg="$(jq -er '.DBParameterGroups[0].DBParameterGroupName' <<<"$expected_replica_source")"
    current_replica_pg="$(jq -er '.DBParameterGroups[0].DBParameterGroupName' <<<"$restored_replica")"
    current_replica_pg_status="$(jq -r '.DBParameterGroups[0].ParameterApplyStatus // "unknown"' <<<"$restored_replica")"
    expected_replica_parameter_file='replica/parameters-1.json'
    if [[ -z "$SOURCE_REPLICA" ]]; then expected_replica_parameter_file='primary/parameters-1.json'; fi
    verify_capture_member "$expected_replica_parameter_file" || exit 2
    awsx rds describe-db-parameters --db-parameter-group-name "$current_replica_pg" --output json \
      > "$PARAMETER_TEMP_DIR/restored-replica.json"
    jq -e '.Parameters|type=="array"' "$PARAMETER_TEMP_DIR/restored-replica.json" >/dev/null \
      || { echo 'Restored replica parameter API response is invalid.' >&2; exit 2; }
    restored_replica_parameter_diffs="$(parameter_diff_rows "$CAPTURE_DIRECTORY/$expected_replica_parameter_file" "$PARAMETER_TEMP_DIR/restored-replica.json")"
    restored_replica_parameter_count="$(jq -r '.Parameters|length' "$CAPTURE_DIRECTORY/$expected_replica_parameter_file")"
    restored_replica_live_count="$(jq -r '.Parameters|length' "$PARAMETER_TEMP_DIR/restored-replica.json")"
    replica_parameter_label='New replica vs captured original replica'
    [[ -n "$SOURCE_REPLICA" ]] || replica_parameter_label='New replica vs captured primary template'
    print_parameter_diffs "$replica_parameter_label" "$restored_replica_parameter_diffs" \
      "$restored_replica_parameter_count" "$restored_replica_live_count"
    if [[ -n "$restored_replica_parameter_diffs" && "$current_replica_pg" == "$expected_replica_pg" ]]; then
      if [[ -n "$SOURCE_REPLICA" ]]; then
        echo 'REFUSED: new replica uses the expected group but its full parameter API differs from the captured original replica. Review the parameter group; this helper cannot reconstruct historical group contents.' >&2
      else
        echo 'REFUSED: new replica uses the expected group but its full parameter API differs from the captured primary template. Review the parameter group; this helper cannot reconstruct historical group contents.' >&2
      fi
      exit 2
    fi
    replica_harden_request="$(build_replica_harden_request "$restored_replica")"
    if [[ "$(jq -r 'keys|length' <<<"$replica_harden_request")" == 2 && "$current_replica_pg" == "$expected_replica_pg" && "$current_replica_pg_status" == in-sync ]]; then
      [[ -z "$restored_replica_parameter_diffs" ]] \
        || { echo 'REFUSED: new replica parameter values still differ from the captured original replica.' >&2; exit 2; }
      printf 'Replica parameter group and maintenance window match baseline and are in-sync; no modify request needed.\n'
      exit 0
    fi
    modify_model="$(awsx rds modify-db-instance --generate-cli-skeleton input)"
    validate_modify_model "$replica_harden_request" "$modify_model" || { echo 'Replica hardening request contains an unsupported API field.' >&2; exit 2; }
    print_harden_table 'Replica post-create hardening (baseline vs current vs ModifyDBInstance)' "$expected_replica_source" "$restored_replica" "$replica_harden_request"
    printf 'Parameter apply status: %s\n' "$current_replica_pg_status"
    confirm APPLY-REPLICA-HARDEN
    request_file="$(mktemp "${TMPDIR:-/tmp}/bb3-replica-harden.XXXXXX")"
    trap cleanup EXIT
    printf '%s\n' "$replica_harden_request" > "$request_file"
    awsx rds modify-db-instance --cli-input-json "file://$request_file" \
      --query 'DBInstance.[DBInstanceStatus,DBParameterGroups[0].DBParameterGroupName,DBParameterGroups[0].ParameterApplyStatus,PreferredMaintenanceWindow]' \
      --output text
    ;;
esac