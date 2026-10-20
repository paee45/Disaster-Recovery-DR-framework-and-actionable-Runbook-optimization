#!/usr/bin/env bash
set -euo pipefail
set +x
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'
else
  GREEN=''; RED=''; RESET=''
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
JQ_LIBRARY="$(<"$ROOT/automation/scripts/rds-requests.jq")"
usage() {
  cat >&2 <<'EOF'
Usage:
  bash iac/lab/bb3-db/restore-drill.sh preview <snapshot-id> <restore-primary-id> <restore-replica-id>
  bash iac/lab/bb3-db/restore-drill.sh restore <snapshot-id> <restore-primary-id> <restore-replica-id>
  bash iac/lab/bb3-db/restore-drill.sh harden-primary <snapshot-id> <restore-primary-id> <restore-replica-id>
  bash iac/lab/bb3-db/restore-drill.sh replica <snapshot-id> <restore-primary-id> <restore-replica-id>
  bash iac/lab/bb3-db/restore-drill.sh harden-replica <snapshot-id> <restore-primary-id> <restore-replica-id>

preview is read-only. restore creates a standalone primary from the snapshot.
harden-primary attaches the captured parameter group if restore did not apply it.
replica creates a new read replica after the restored primary is available.
harden-replica applies captured parameter/maintenance settings after replica availability.
Every mutating action displays its comparison table and requires typed approval.
EOF
  exit 2
}
[[ $# == 4 ]] || usage
MODE="$1"; SNAPSHOT_ID="$2"; TARGET_PRIMARY="$3"; TARGET_REPLICA="$4"
[[ "$MODE" =~ ^(preview|restore|harden-primary|replica|harden-replica)$ ]] || usage
[[ "$SNAPSHOT_ID" =~ ^[A-Za-z0-9][A-Za-z0-9:_-]*$ ]] || { echo 'Invalid snapshot identifier.' >&2; exit 2; }
for id in "$TARGET_PRIMARY" "$TARGET_REPLICA"; do
  [[ "$id" =~ ^[A-Za-z][A-Za-z0-9-]{0,62}$ ]] || { echo 'Invalid target DB identifier.' >&2; exit 2; }
done
[[ "$TARGET_PRIMARY" != "$TARGET_REPLICA" ]] || { echo 'Primary and replica targets must differ.' >&2; exit 2; }

CONFIG="$ROOT/iac/sandbox.env"
[[ -f "$CONFIG" ]] || { echo 'Missing ignored iac/sandbox.env.' >&2; exit 2; }
git -C "$ROOT" check-ignore -q "$CONFIG" || { echo 'Refusing non-ignored sandbox config.' >&2; exit 2; }
[[ -z "${AWS_ACCESS_KEY_ID:-}${AWS_SECRET_ACCESS_KEY:-}${AWS_SESSION_TOKEN:-}" ]] \
  || { echo 'Unset exported AWS credentials; use the configured named profile.' >&2; exit 2; }
# shellcheck source=/dev/null
source "${BB3_RESTORE_CONFIG:-$CONFIG}"
unset TF_VAR_terrakube_token AWS_DEFAULT_PROFILE
PROFILE="${TF_VAR_aws_profile:-}"
REGION="${TF_VAR_region:-}"
ACCOUNT="${TF_VAR_account_id:-}"
[[ "$PROFILE" =~ ^(lab_sandbox|pa_aws_sandbox|pa_iam_aws_sandbox)$ && "$REGION" == ap-southeast-1 \
  && "$ACCOUNT" =~ ^[0-9]{12}$ ]] || { echo 'Sandbox profile, account or region is invalid.' >&2; exit 2; }
awsx() { aws --profile "$PROFILE" --region "$REGION" --no-cli-pager "$@"; }
CALLER_ACCOUNT="$(awsx sts get-caller-identity --query Account --output text)"
[[ "$CALLER_ACCOUNT" == "$ACCOUNT" ]] || { echo 'AWS caller does not match the configured sandbox account.' >&2; exit 2; }

snapshot="$(awsx rds describe-db-snapshots --db-snapshot-identifier "$SNAPSHOT_ID" --output json)"
[[ "$(jq -r '.DBSnapshots | length' <<<"$snapshot")" == 1 ]] || { echo 'Snapshot was not found uniquely.' >&2; exit 2; }
[[ "$(jq -r '.DBSnapshots[0].Status' <<<"$snapshot")" == available ]] || { echo 'Snapshot is not available.' >&2; exit 2; }
SOURCE_PRIMARY="$(jq -er '.DBSnapshots[0].DBInstanceIdentifier' <<<"$snapshot")"
primary="$(awsx rds describe-db-instances --db-instance-identifier "$SOURCE_PRIMARY" --query 'DBInstances[0]' --output json)"
[[ "$(jq -r '.DBInstanceStatus' <<<"$primary")" == available ]] || { echo 'Source primary is not available.' >&2; exit 2; }
replica_ids="$(jq -c '[.ReadReplicaDBInstanceIdentifiers[]? | split(":") | last]' <<<"$primary")"
[[ "$(jq -r 'length' <<<"$replica_ids")" -le 1 ]] || { echo 'Expected at most one source read replica.' >&2; exit 2; }
SOURCE_REPLICA="$(jq -r '.[0] // empty' <<<"$replica_ids")"
if [[ -n "$SOURCE_REPLICA" ]]; then
  replica="$(awsx rds describe-db-instances --db-instance-identifier "$SOURCE_REPLICA" --query 'DBInstances[0]' --output json)"
  [[ "$(jq -r '.DBInstanceStatus' <<<"$replica")" == available ]] || { echo 'Source replica is not available.' >&2; exit 2; }
  [[ "$(jq -r '.ReadReplicaSourceDBInstanceIdentifier | split(":") | last' <<<"$replica")" == "$SOURCE_PRIMARY" ]] \
    || { echo 'Source replica is not attached to the snapshot source primary.' >&2; exit 2; }
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
primary_tags="$(awsx rds list-tags-for-resource --resource-name "$(jq -er '.DBInstanceArn' <<<"$primary")" --query TagList --output json)"
if [[ -n "$SOURCE_REPLICA" ]]; then
  replica_tags="$(awsx rds list-tags-for-resource --resource-name "$(jq -er '.DBInstanceArn' <<<"$replica")" --query TagList --output json)"
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
       (if .[1]==null then "NEW" elif (.[1]|tojson)==(.[2]|tojson) then "MATCH" else "DIFF - REVIEW" end)] | @tsv
  ' | while IFS=$'\t' read -r field original value check; do
    case "$check" in
      MATCH) check="${GREEN}MATCH${RESET}" ;;
      'DIFF - REVIEW') check="${RED}DIFF - REVIEW${RESET}" ;;
    esac
    printf '%-26s | %-34s | %-34s | %s\n' "$field" "${original:-not set}" "$value" "$check"
  done
}

print_primary_confirmation() {
  printf 'Snapshot: %s (source primary: %s)\n' "$SNAPSHOT_ID" "$SOURCE_PRIMARY"
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
  local token="$1" answer
  [[ -t 0 && -t 1 ]] || { echo 'Confirmation requires an interactive terminal.' >&2; exit 2; }
  read -r -p "Type $token to continue: " answer </dev/tty
  [[ "$answer" == "$token" ]] || { echo 'Cancelled; no RDS request was submitted.'; exit 2; }
}

case "$MODE" in
  preview)
    print_preview
    ;;
  restore)
    require_absent "$TARGET_PRIMARY"
    require_absent "$TARGET_REPLICA"
    print_primary_confirmation
    confirm RESTORE
    umask 077
    request_file="$(mktemp "${TMPDIR:-/tmp}/bb3-restore-request.XXXXXX")"
    trap 'rm -f "$request_file"' EXIT
    printf '%s\n' "$restore_request" > "$request_file"
    awsx rds restore-db-instance-from-db-snapshot --cli-input-json "file://$request_file" \
      --query 'DBInstance.[DBInstanceStatus,DBInstanceClass,PubliclyAccessible,BackupRetentionPeriod]' --output text
    printf 'Primary restore started. After it is available, harden/check its parameter group with:\n'
    printf 'bash iac/lab/bb3-db/restore-drill.sh harden-primary %q %q %q\n' "$SNAPSHOT_ID" "$TARGET_PRIMARY" "$TARGET_REPLICA"
    printf 'Then create the replica with:\n'
    printf 'bash iac/lab/bb3-db/restore-drill.sh replica %q %q %q\n' "$SNAPSHOT_ID" "$TARGET_PRIMARY" "$TARGET_REPLICA"
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
    printf 'bash iac/lab/bb3-db/restore-drill.sh harden-replica %q %q %q\n' "$SNAPSHOT_ID" "$TARGET_PRIMARY" "$TARGET_REPLICA"
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