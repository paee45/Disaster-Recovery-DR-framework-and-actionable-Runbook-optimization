#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
STORE="$HERE/baselines"
print_summary_table() {
  local capture_dir="$1" field filter primary_value replica_value
  local primary_file="$capture_dir/primary/baseline.json" replica_file="$capture_dir/replica/baseline.json"
  local primary_parameters replica_parameters primary_parameter_file replica_parameter_file
  printf '\nBaseline at a glance: %s\n' "$capture_dir"
  printf '%-28s | %-48s | %s\n' 'Captured setting' 'Primary' 'Replica'
  printf '%s\n' '-----------------------------+--------------------------------------------------+--------------------------------------------------'
  while IFS=$'\t' read -r field filter; do
    [[ -n "$field" ]] || continue
    if [[ -f "$primary_file" ]]; then primary_value="$(jq -r "$filter" "$primary_file")"; else primary_value='not present'; fi
    if [[ -f "$replica_file" ]]; then replica_value="$(jq -r "$filter" "$replica_file")"; else replica_value='not present'; fi
    printf '%-28s | %-48s | %s\n' "$field" "$primary_value" "$replica_value"
  done <<'EOF'
Source ID	.source // "not captured"
Engine	.instance.Engine // "not reported"
Engine version	.instance.EngineVersion // "not reported"
Instance class	.instance.DBInstanceClass // "not reported"
Availability zone	.instance.AvailabilityZone // "not reported"
Parameter group	.instance.DBParameterGroups[0].DBParameterGroupName // "not reported"
Parameter apply status	.instance.DBParameterGroups[0].ParameterApplyStatus // "not reported"
Subnet group	.instance.DBSubnetGroup.DBSubnetGroupName // "not reported"
Security groups	([.instance.VpcSecurityGroups[]?.VpcSecurityGroupId] | join(", ")) // "not reported"
Publicly accessible	(.instance.PubliclyAccessible | tostring) // "not reported"
Multi-AZ	(.instance.MultiAZ | tostring) // "not reported"
Backup retention days	(.instance.BackupRetentionPeriod | tostring) // "not reported"
Backup window	.instance.PreferredBackupWindow // "not reported"
Maintenance window	.instance.PreferredMaintenanceWindow // "not reported"
Storage encrypted	(.instance.StorageEncrypted | tostring) // "not reported"
Tag env	([.tags[]? | select(.Key=="env") | .Value] | first) // "not present"
Tag app	([.tags[]? | select(.Key=="app") | .Value] | first) // "not present"
Tag Role	([.tags[]? | select(.Key=="Role") | .Value] | first) // "not present"
EOF
  primary_parameter_file="$capture_dir/primary/parameters-1.json"
  replica_parameter_file="$capture_dir/replica/parameters-1.json"
  primary_parameters='not present'; replica_parameters='not present'
  if [[ -f "$primary_parameter_file" ]]; then
    primary_parameters="$(jq -r '[.Parameters[]? | select(.Source=="user") | "\(.ParameterName)=\(.ParameterValue)"] | if length==0 then "none" else join(", ") end' "$primary_parameter_file")"
  fi
  if [[ -f "$replica_parameter_file" ]]; then
    replica_parameters="$(jq -r '[.Parameters[]? | select(.Source=="user") | "\(.ParameterName)=\(.ParameterValue)"] | if length==0 then "none" else join(", ") end' "$replica_parameter_file")"
  fi
  printf '%-28s | %-48s | %s\n' 'User parameter overrides' "$primary_parameters" "$replica_parameters"
  printf '%s\n' 'Full API metadata, all parameter responses, and SHA-256 manifest remain in the capture directory.'
}
if [[ $# == 1 && "$1" == --show ]]; then
  latest_file="$STORE/latest.json"
  [[ -f "$latest_file" ]] || { echo 'No completed baseline exists yet.' >&2; exit 2; }
  latest_directory="$(jq -er '.directory | select(test("^[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9]+$"))' "$latest_file")" \
    || { echo 'Latest baseline reference is invalid.' >&2; exit 2; }
  capture_dir="$STORE/$latest_directory"
  [[ "$(jq -r '.status' "$latest_file")" == complete && -f "$capture_dir/primary/baseline.json" ]] \
    || { echo 'Latest baseline capture is incomplete.' >&2; exit 2; }
  print_summary_table "$capture_dir"
  exit 0
fi
if [[ $# -gt 2 ]]; then
  echo "Usage: bash iac/lab/bb3-db/capture-baseline.sh [--show | primary-db-id [replica-db-id]]" >&2
  exit 2
fi
if [[ $# == 0 ]]; then
  DRILL_ENV_FILE="${BB3_DRILL_ENV_FILE:-$ROOT/iac/sandbox.env}"
  git -C "$ROOT" check-ignore -q "$DRILL_ENV_FILE" \
    || { echo 'REFUSED: BB3 drill env file must be git-ignored.' >&2; exit 2; }
  [[ -f "$DRILL_ENV_FILE" ]] || { echo "Missing $DRILL_ENV_FILE; run discover-env.sh first." >&2; exit 2; }
  # shellcheck source=/dev/null
  source "$DRILL_ENV_FILE"
  unset TF_VAR_terrakube_token
  PRIMARY="${BB3_SOURCE_PRIMARY_ID:-}"
  REPLICA="${BB3_SOURCE_REPLICA_ID:-}"
else
  PRIMARY="$1"; REPLICA="${2:-}"
fi
[[ "$PRIMARY" =~ ^[A-Za-z][A-Za-z0-9-]*$ ]] \
  || { echo 'A valid primary RDS instance identifier is required.' >&2; exit 2; }
if [[ -n "$REPLICA" ]]; then
  [[ "$REPLICA" =~ ^[A-Za-z][A-Za-z0-9-]*$ && "$PRIMARY" != "$REPLICA" ]] \
    || { echo 'Replica identifier must be valid and distinct from the primary.' >&2; exit 2; }
fi
export AWS_PROFILE="${AWS_PROFILE:-${BB3_AWS_PROFILE:-beep}}" AWS_REGION="${AWS_REGION:-${BB3_AWS_REGION:-ap-southeast-1}}"
[[ -z "${AWS_ACCESS_KEY_ID:-}${AWS_SECRET_ACCESS_KEY:-}${AWS_SESSION_TOKEN:-}" ]] \
  || { echo 'REFUSED: unset exported AWS credentials; use the named profile.' >&2; exit 2; }
unset AWS_DEFAULT_PROFILE
git -C "$ROOT" check-ignore -q "$STORE/capture.json" \
  || { echo 'REFUSED: raw baseline directory must be git-ignored.' >&2; exit 2; }
mkdir -p "$STORE"
CAPTURE="$(mktemp -d "$STORE/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
complete=false
trap 'if [[ "$complete" != true ]]; then echo "Incomplete capture retained at $CAPTURE; latest.json was not changed." >&2; fi' EXIT
aws --profile "$AWS_PROFILE" --region "$AWS_REGION" sts get-caller-identity --output json > "$CAPTURE/identity.json"
jq -e '.Account | test("^[0-9]{12}$")' "$CAPTURE/identity.json" >/dev/null
ACCOUNT="$(jq -r .Account "$CAPTURE/identity.json")"
if [[ -n "${BB3_ACCOUNT_ID:-}" && "$ACCOUNT" != "$BB3_ACCOUNT_ID" ]]; then
  echo 'REFUSED: discovered baseline account does not match the current caller.' >&2
  exit 2
fi
roles=(primary); [[ -n "$REPLICA" ]] && roles+=(replica)
for role in "${roles[@]}"; do
  db="$PRIMARY"; [[ "$role" != replica ]] || db="$REPLICA"
  directory="$CAPTURE/$role"
  mkdir -p "$directory"
  aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-instances \
    --db-instance-identifier "$db" --output json > "$directory/instance.json"
  jq -e --arg db "$db" --arg account "$ACCOUNT" '
    (.DBInstances | length) == 1 and (.DBInstances[0] |
      .DBInstanceIdentifier == $db and .Engine == "postgres" and
      (.DBInstanceArn | split(":")[4]) == $account)' "$directory/instance.json" >/dev/null
  arn="$(jq -r '.DBInstances[0].DBInstanceArn' "$directory/instance.json")"
  aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds list-tags-for-resource \
    --resource-name "$arn" --output json > "$directory/tags.json"
  jq -e '.TagList | type == "array"' "$directory/tags.json" >/dev/null
  groups="$(jq -er '.DBInstances[0].DBParameterGroups | if length > 0 then .[].DBParameterGroupName else error("No parameter group") end' "$directory/instance.json")"
  group_index=0
  while IFS= read -r group; do
    group_index=$((group_index + 1))
    aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-parameter-groups \
      --db-parameter-group-name "$group" --output json > "$directory/parameter-group-$group_index.json"
    aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-parameters \
      --db-parameter-group-name "$group" --output json > "$directory/parameters-$group_index.json"
    jq -e '(.DBParameterGroups | length) == 1' "$directory/parameter-group-$group_index.json" >/dev/null
    jq -e '.Parameters | type == "array"' "$directory/parameters-$group_index.json" >/dev/null
  done <<< "$groups"
  subnet_group="$(jq -er '.DBInstances[0].DBSubnetGroup.DBSubnetGroupName' "$directory/instance.json")"
  aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-subnet-groups \
    --db-subnet-group-name "$subnet_group" --output json > "$directory/subnet-group.json"
  group_ids="$(jq -er '.DBInstances[0].VpcSecurityGroups | if length > 0 then map(.VpcSecurityGroupId) | join(" ") else error("No security group") end' "$directory/instance.json")"
  read -r -a security_groups <<< "$group_ids"
  aws --profile "$AWS_PROFILE" --region "$AWS_REGION" ec2 describe-security-groups \
    --group-ids "${security_groups[@]}" --output json > "$directory/security-groups.json"
  subnet_ids="$(jq -er '.DBSubnetGroups[0].Subnets | if length > 0 then map(.SubnetIdentifier) | join(" ") else error("No subnets") end' "$directory/subnet-group.json")"
  read -r -a subnets <<< "$subnet_ids"
  aws --profile "$AWS_PROFILE" --region "$AWS_REGION" ec2 describe-subnets \
    --subnet-ids "${subnets[@]}" --output json > "$directory/subnets.json"
  jq -e '.SecurityGroups | type == "array" and length > 0' "$directory/security-groups.json" >/dev/null
  jq -e '.Subnets | type == "array" and length > 0' "$directory/subnets.json" >/dev/null
  jq -n --slurpfile description "$directory/instance.json" --slurpfile tags "$directory/tags.json" \
    --arg source "$db" --arg account "$ACCOUNT" --arg region "$AWS_REGION" --arg at "$(date -u +%FT%TZ)" \
    '{capturedAt:$at,env:"uat",account:$account,region:$region,source:$source,
      instance:$description[0].DBInstances[0],tags:$tags[0].TagList,pgSettings:{},
      validationScope:"AWS API configuration only; no SQL or credential access"}' > "$directory/baseline.json"
done
if [[ -n "$REPLICA" ]]; then
  jq -e --slurpfile source_instance "$CAPTURE/primary/instance.json" --arg primary "$PRIMARY" --arg replica "$REPLICA" '
    (.DBInstances[0].ReadReplicaSourceDBInstanceIdentifier | split(":") | last) == $primary and
    ($source_instance[0].DBInstances[0].ReadReplicaDBInstanceIdentifiers | index($replica)) != null' \
    "$CAPTURE/replica/instance.json" >/dev/null
else
  jq -e '.DBInstances[0].ReadReplicaDBInstanceIdentifiers // [] | length == 0' \
    "$CAPTURE/primary/instance.json" >/dev/null \
    || { echo 'Primary has attached read replicas; supply the intended replica identifier to capture them too.' >&2; exit 2; }
fi
jq -n --arg at "$(date -u +%FT%TZ)" --arg profile "$AWS_PROFILE" --arg region "$AWS_REGION" \
  --arg directory "$(basename "$CAPTURE")" --arg replica "$REPLICA" \
  '{schemaVersion:1,status:"complete",capturedAt:$at,profile:$profile,region:$region,directory:$directory,
    primary:"primary/baseline.json",replica:(if $replica=="" then null else "replica/baseline.json" end),
    parameters:"Each role contains full paginated AWS parameter definitions and values, not SQL pg_settings"}' \
  > "$CAPTURE/capture.json"
hash_command=(shasum -a 256)
command -v sha256sum >/dev/null 2>&1 && hash_command=(sha256sum)
manifest_entries=()
while IFS= read -r file; do
  digest="$("${hash_command[@]}" "$file")"; digest="${digest%% *}"
  manifest_entries+=("$(jq -nc --arg path "${file#"$CAPTURE/"}" --arg sha256 "$digest" '{path:$path,sha256:$sha256}')")
done < <(find "$CAPTURE" -type f | sort)
printf '%s\n' "${manifest_entries[@]}" | jq -s '{files:.}' > "$CAPTURE/manifest.json"
cp "$CAPTURE/capture.json" "$STORE/.latest-$(basename "$CAPTURE").json"
mv "$STORE/.latest-$(basename "$CAPTURE").json" "$STORE/latest.json"
complete=true
echo "Complete read-only raw baseline: $CAPTURE"
echo "Latest reference: $STORE/latest.json"
print_summary_table "$CAPTURE"