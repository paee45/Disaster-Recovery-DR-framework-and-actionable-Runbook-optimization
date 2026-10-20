#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
if [[ $# != 2 ]]; then
  echo "Usage: bash iac/lab/bb3-db/capture-baseline.sh <primary-db-id> <replica-db-id>" >&2
  exit 2
fi
PRIMARY="$1"; REPLICA="$2"
[[ "$PRIMARY" =~ ^[A-Za-z][A-Za-z0-9-]*$ && "$REPLICA" =~ ^[A-Za-z][A-Za-z0-9-]*$ && "$PRIMARY" != "$REPLICA" ]] \
  || { echo 'Two distinct RDS instance identifiers are required.' >&2; exit 2; }
export AWS_PROFILE="${AWS_PROFILE:-beep}" AWS_REGION="${AWS_REGION:-ap-southeast-1}"
[[ -z "${AWS_ACCESS_KEY_ID:-}${AWS_SECRET_ACCESS_KEY:-}${AWS_SESSION_TOKEN:-}" ]] \
  || { echo 'REFUSED: unset exported AWS credentials; use the named profile.' >&2; exit 2; }
unset AWS_DEFAULT_PROFILE
STORE="$HERE/baselines"
git -C "$ROOT" check-ignore -q "$STORE/capture.json" \
  || { echo 'REFUSED: raw baseline directory must be git-ignored.' >&2; exit 2; }
mkdir -p "$STORE"
CAPTURE="$(mktemp -d "$STORE/$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
complete=false
trap 'if [[ "$complete" != true ]]; then echo "Incomplete capture retained at $CAPTURE; latest.json was not changed." >&2; fi' EXIT
aws --profile "$AWS_PROFILE" --region "$AWS_REGION" sts get-caller-identity --output json > "$CAPTURE/identity.json"
jq -e '.Account | test("^[0-9]{12}$")' "$CAPTURE/identity.json" >/dev/null
ACCOUNT="$(jq -r .Account "$CAPTURE/identity.json")"
for role in primary replica; do
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
jq -e --slurpfile source_instance "$CAPTURE/primary/instance.json" --arg primary "$PRIMARY" --arg replica "$REPLICA" '
  (.DBInstances[0].ReadReplicaSourceDBInstanceIdentifier | split(":") | last) == $primary and
  ($source_instance[0].DBInstances[0].ReadReplicaDBInstanceIdentifiers | index($replica)) != null' \
  "$CAPTURE/replica/instance.json" >/dev/null
jq -n --arg at "$(date -u +%FT%TZ)" --arg profile "$AWS_PROFILE" --arg region "$AWS_REGION" \
  --arg directory "$(basename "$CAPTURE")" \
  '{schemaVersion:1,status:"complete",capturedAt:$at,profile:$profile,region:$region,directory:$directory,
    primary:"primary/baseline.json",replica:"replica/baseline.json",
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