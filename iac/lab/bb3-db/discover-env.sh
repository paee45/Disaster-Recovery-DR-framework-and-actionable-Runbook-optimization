#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
CONFIG="${BB3_SANDBOX_CONFIG:-$ROOT/iac/sandbox.env}"
ENV_FILE="${BB3_DRILL_ENV_FILE:-$CONFIG}"
usage() {
  echo 'Usage: discover-env.sh <dev|uat|prod> [--print|--write] [--force] [--primary ID] [--replica ID] [--snapshot ID]' >&2
  exit 2
}
[[ $# -ge 1 ]] || usage
ENVIRONMENT="$1"; shift
[[ "$ENVIRONMENT" =~ ^(dev|uat|prod)$ ]] || usage
MODE=summary; FORCE=false; MANUAL_PRIMARY=''; MANUAL_REPLICA=''; MANUAL_SNAPSHOT=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --print) MODE=print; shift ;;
    --write) MODE=write; shift ;;
    --force) FORCE=true; shift ;;
    --primary|--replica|--snapshot)
      [[ $# -ge 2 ]] || usage
      case "$1" in
        --primary) MANUAL_PRIMARY="$2" ;;
        --replica) MANUAL_REPLICA="$2" ;;
        --snapshot) MANUAL_SNAPSHOT="$2" ;;
      esac
      shift 2 ;;
    *) usage ;;
  esac
done
[[ -f "$CONFIG" ]] || { echo 'Missing iac/sandbox.env.' >&2; exit 2; }
git -C "$ROOT" check-ignore -q "$ENV_FILE" || { echo 'Env target must be git-ignored.' >&2; exit 2; }
[[ -z "${AWS_ACCESS_KEY_ID:-}${AWS_SECRET_ACCESS_KEY:-}${AWS_SESSION_TOKEN:-}" ]] || { echo 'Unset exported AWS keys.' >&2; exit 2; }
# shellcheck source=/dev/null
source "$CONFIG"
unset TF_VAR_terrakube_token AWS_DEFAULT_PROFILE
PROFILE="${TF_VAR_aws_profile:-}"
REGION="${TF_VAR_region:-}"
ACCOUNT="${TF_VAR_account_id:-}"
[[ "$PROFILE" =~ ^(lab_sandbox|pa_aws_sandbox|pa_iam_aws_sandbox)$ && "$REGION" == ap-southeast-1 \
  && "$ACCOUNT" =~ ^[0-9]{12}$ ]] || { echo 'Invalid sandbox profile/account/region.' >&2; exit 2; }
awsx() { aws --profile "$PROFILE" --region "$REGION" --no-cli-pager "$@"; }
CALLER="$(awsx sts get-caller-identity --query Account --output text)"
[[ "$CALLER" == "$ACCOUNT" ]] || { echo 'Caller account mismatch.' >&2; exit 2; }
for id in "$MANUAL_PRIMARY" "$MANUAL_REPLICA"; do
  [[ -z "$id" || "$id" =~ ^[A-Za-z][A-Za-z0-9-]*$ ]] || { echo 'Invalid manual DB identifier.' >&2; exit 2; }
done
instance_json="$(awsx rds describe-db-instances --output json)"
candidate_arns="$(jq -r --arg prefix "dr-sandbox-bb3-${ENVIRONMENT}-" '
  .DBInstances[]? | select(.Engine=="postgres" and .DBInstanceStatus=="available" and (.DBInstanceIdentifier|startswith($prefix))) | .DBInstanceArn
' <<<"$instance_json")"
candidate_ids=()
while IFS= read -r instance_arn; do
  [[ -n "$instance_arn" ]] || continue
  instance_id="${instance_arn##*:db:}"
  tags="$(awsx rds list-tags-for-resource --resource-name "$instance_arn" --query TagList --output json)"
  if jq -e --arg env "$ENVIRONMENT" '
    any(.[]; .Key=="app" and .Value=="bb3-sandbox") and
    any(.[]; .Key=="dr-env" and .Value==$env) and
    any(.[]; .Key=="repo-path" and .Value=="iac/lab/bb3-db") and
    any(.[]; .Key=="Role" and .Value=="primary")
  ' <<<"$tags" >/dev/null; then
    candidate_ids+=("$instance_id")
  fi
done < <(printf '%s\n' "$candidate_arns")
if [[ -n "$MANUAL_PRIMARY" ]]; then
  printf '%s\n' "${candidate_ids[@]}" | grep -Fxq "$MANUAL_PRIMARY" \
    || { echo 'Manual primary is not an available, correctly tagged BB3 sandbox primary.' >&2; exit 2; }
  SOURCE_PRIMARY="$MANUAL_PRIMARY"
else
  if ((${#candidate_ids[@]} == 1)); then
    SOURCE_PRIMARY="${candidate_ids[0]}"
  elif [[ "$MODE" == write && -t 0 && -t 1 && ${#candidate_ids[@]} -gt 1 ]]; then
    printf 'Multiple eligible %s primaries found; select one:\n' "$ENVIRONMENT"
    for index in "${!candidate_ids[@]}"; do printf '  %d) %s\n' "$((index+1))" "${candidate_ids[$index]}"; done
    read -r -p 'Selection: ' selection </dev/tty
    [[ "$selection" =~ ^[0-9]+$ ]] && ((selection>=1 && selection<=${#candidate_ids[@]})) \
      || { echo 'Invalid primary selection.' >&2; exit 2; }
    SOURCE_PRIMARY="${candidate_ids[$((selection-1))]}"
  else
    printf 'Found %s eligible primary candidates; select one with --primary <id>.\n' "${#candidate_ids[@]}" >&2
    printf '%s\n' "${candidate_ids[@]}" >&2
    exit 2
  fi
fi
primary="$(awsx rds describe-db-instances --db-instance-identifier "$SOURCE_PRIMARY" --query 'DBInstances[0]' --output json)"
attached="$(jq -c '[.ReadReplicaDBInstanceIdentifiers[]? | split(":") | last]' <<<"$primary")"
(( $(jq -r 'length' <<<"$attached") <= 1 )) || { echo 'More than one attached replica; manual topology review is required.' >&2; exit 2; }
AUTO_REPLICA="$(jq -r '.[0] // empty' <<<"$attached")"
if [[ -n "$MANUAL_REPLICA" ]]; then
  jq -e --arg id "$MANUAL_REPLICA" 'index($id)!=null' <<<"$attached" >/dev/null \
    || { echo 'Manual replica is not attached to the selected primary.' >&2; exit 2; }
  SOURCE_REPLICA="$MANUAL_REPLICA"
else
  SOURCE_REPLICA="$AUTO_REPLICA"
fi
if [[ -n "$SOURCE_REPLICA" ]]; then
  replica="$(awsx rds describe-db-instances --db-instance-identifier "$SOURCE_REPLICA" --query 'DBInstances[0]' --output json)"
  [[ "$(jq -r '.DBInstanceStatus' <<<"$replica")" == available ]] || { echo 'Discovered replica is not available.' >&2; exit 2; }
  [[ "$(jq -r '.ReadReplicaSourceDBInstanceIdentifier|split(":")|last' <<<"$replica")" == "$SOURCE_PRIMARY" ]] \
    || { echo 'Discovered replica source does not match the selected primary.' >&2; exit 2; }
fi
if [[ -n "$MANUAL_SNAPSHOT" ]]; then
  snapshot="$(awsx rds describe-db-snapshots --db-snapshot-identifier "$MANUAL_SNAPSHOT" --output json)"
  [[ "$(jq -r '.DBSnapshots|length' <<<"$snapshot")" == 1 && "$(jq -r '.DBSnapshots[0].Status' <<<"$snapshot")" == available \
    && "$(jq -r '.DBSnapshots[0].DBInstanceIdentifier' <<<"$snapshot")" == "$SOURCE_PRIMARY" ]] \
    || { echo 'Manual snapshot must be available and belong to the selected primary.' >&2; exit 2; }
  SNAPSHOT_ID="$MANUAL_SNAPSHOT"
else
  snapshots="$(awsx rds describe-db-snapshots --db-instance-identifier "$SOURCE_PRIMARY" --snapshot-type automated --output json)"
  SNAPSHOT_ID="$(jq -r '[.DBSnapshots[]? | select(.Status=="available")] | sort_by(.SnapshotCreateTime) | last | .DBSnapshotIdentifier // empty' <<<"$snapshots")"
fi
SNAPSHOT_TIME=''
if [[ -n "$SNAPSHOT_ID" ]]; then
  SNAPSHOT_TIME="$(awsx rds describe-db-snapshots --db-snapshot-identifier "$SNAPSHOT_ID" --query 'DBSnapshots[0].SnapshotCreateTime' --output text)"
fi
DISCOVERED_AT="$(date -u +%FT%TZ)"
print_summary() {
  printf 'Environment: %s\nPrimary: %s\n' "$ENVIRONMENT" "$SOURCE_PRIMARY"
  if [[ -n "$SOURCE_REPLICA" ]]; then printf 'Replica: %s\n' "$SOURCE_REPLICA"; else printf '%s\n' 'Replica: not present'; fi
  if [[ -n "$SNAPSHOT_ID" ]]; then printf 'Snapshot candidate: %s (%s)\n' "$SNAPSHOT_ID" "$SNAPSHOT_TIME"; else printf '%s\n' 'No automated snapshot candidate; select a manual snapshot with --snapshot.'; fi
  printf 'Caller/account verified; discovered at %s. No secret values were read.\n' "$DISCOVERED_AT"
}
print_env() {
  printf 'export BB3_ENV=%q\n' "$ENVIRONMENT"
  printf 'export BB3_AWS_PROFILE=%q\n' "$PROFILE"
  printf 'export BB3_AWS_REGION=%q\n' "$REGION"
  printf 'export BB3_ACCOUNT_ID=%q\n' "$ACCOUNT"
  printf 'export BB3_SOURCE_PRIMARY_ID=%q\n' "$SOURCE_PRIMARY"
  printf 'export BB3_SOURCE_REPLICA_ID=%q\n' "$SOURCE_REPLICA"
  printf 'export BB3_SNAPSHOT_ID=%q\n' "$SNAPSHOT_ID"
  printf 'export BB3_SNAPSHOT_TIME=%q\n' "$SNAPSHOT_TIME"
  printf 'export BB3_DISCOVERED_AT=%q\n' "$DISCOVERED_AT"
}
case "$MODE" in
  print) print_env ;;
  write)
    [[ -t 0 && -t 1 ]] || { echo 'Refusing non-interactive write; use --print to review first.' >&2; exit 2; }
    bb3_keys='ENV|AWS_PROFILE|AWS_REGION|ACCOUNT_ID|SOURCE_PRIMARY_ID|SOURCE_REPLICA_ID|SNAPSHOT_ID|SNAPSHOT_TIME|DISCOVERED_AT'
    if grep -Eq "^export BB3_($bb3_keys)=" "$ENV_FILE" && [[ "$FORCE" != true ]]; then
      echo 'BB3 discovery values already exist; review and pass --force to refresh them.' >&2
      exit 2
    fi
    print_summary
    read -r -p 'Type WRITE to update only BB3_* variables in iac/sandbox.env: ' answer </dev/tty
    [[ "$answer" == WRITE ]] || { echo 'Cancelled; sandbox.env unchanged.'; exit 2; }
    temp_file="$(mktemp "${ENV_FILE}.tmp.XXXXXX")"
    trap 'rm -f "$temp_file"' EXIT
    awk -v keys="$bb3_keys" '$0 !~ "^export BB3_(" keys ")="' "$ENV_FILE" > "$temp_file"
    print_env >> "$temp_file"
    chmod 600 "$temp_file"
    mv -f "$temp_file" "$ENV_FILE"
    trap - EXIT
    printf 'Wrote source-selection inputs to ignored file: %s\n' "$ENV_FILE"
    ;;
  summary)
    print_summary
    ;;
esac