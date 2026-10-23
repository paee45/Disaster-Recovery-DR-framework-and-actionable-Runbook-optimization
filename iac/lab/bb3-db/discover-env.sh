#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'
else
  GREEN=''; RED=''; RESET=''
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bb3-prompt.sh
source "$HERE/bb3-prompt.sh"
ROOT="$(cd "$HERE/../../.." && pwd)"
CONFIG="${BB3_SANDBOX_CONFIG:-$ROOT/iac/sandbox.env}"
ENV_FILE="${BB3_DRILL_ENV_FILE:-$CONFIG}"
usage() {
  echo 'Usage: discover-env.sh <dev|uat|prod> [--print] [--primary ID] [--replica ID] [--snapshot ID]' >&2
  exit 2
}
[[ $# -ge 1 ]] || usage
ENVIRONMENT="$1"; shift
[[ "$ENVIRONMENT" =~ ^(dev|uat|prod)$ ]] || usage
MODE=interactive; MANUAL_PRIMARY=''; MANUAL_REPLICA=''; MANUAL_SNAPSHOT=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --print) MODE=print; shift ;;
    --write|--force) MODE=interactive; shift ;;
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
[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE." >&2; exit 2; }
git -C "$ROOT" check-ignore -q "$ENV_FILE" || { echo 'Env target must be git-ignored.' >&2; exit 2; }
[[ -z "${AWS_ACCESS_KEY_ID:-}${AWS_SECRET_ACCESS_KEY:-}${AWS_SESSION_TOKEN:-}" ]] || { echo 'Unset exported AWS keys.' >&2; exit 2; }
# shellcheck source=/dev/null
source "$ENV_FILE"
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
available_records="$(jq -r '
  .DBInstances[]? | select(.Engine=="postgres" and .DBInstanceStatus=="available") |
  [.DBInstanceIdentifier,.DBInstanceArn,(.ReadReplicaSourceDBInstanceIdentifier // "")] | @tsv
' <<<"$instance_json")"
candidate_ids=(); all_primary_ids=(); all_ids=(); tagged_ids=(); FALLBACK=false
while IFS=$'\t' read -r instance_id instance_arn replica_source; do
  [[ -n "$instance_id" && -n "$instance_arn" ]] || continue
  all_ids+=("$instance_id")
  [[ -n "$replica_source" ]] || all_primary_ids+=("$instance_id")
  tags="$(awsx rds list-tags-for-resource --resource-name "$instance_arn" --query TagList --output json)"
  if jq -e --arg env "$ENVIRONMENT" '
    any(.[]; .Key=="app" and .Value=="bb3") and
    any(.[]; .Key=="env" and .Value==$env)
  ' <<<"$tags" >/dev/null; then
    tagged_ids+=("$instance_id")
    [[ -n "$replica_source" ]] || candidate_ids+=("$instance_id")
  fi
done < <(printf '%s\n' "$available_records")
if ((${#candidate_ids[@]} == 0)); then
  FALLBACK=true
  candidate_ids=("${all_primary_ids[@]}")
  ((${#candidate_ids[@]} > 0)) || { echo 'No available PostgreSQL RDS primary candidates were found.' >&2; exit 2; }
  RED=$'\033[31m'; RESET=$'\033[0m'
  printf '%b\n' "${RED}WARNING: no available RDS primary matched env=$ENVIRONMENT and app=bb3; showing all available PostgreSQL RDS instances. Verify the source before continuing.${RESET}"
  for instance_id in "${all_ids[@]}"; do
    if printf '%s\n' "${all_primary_ids[@]}" | grep -Fxq "$instance_id"; then
      printf '%b\n' "${RED}  ${instance_id} [primary candidate]${RESET}"
    else
      printf '%b\n' "${RED}  ${instance_id} [replica, not selectable as primary]${RESET}"
    fi
  done
fi
if [[ -n "$MANUAL_PRIMARY" ]]; then
  printf '%s\n' "${candidate_ids[@]}" | grep -Fxq "$MANUAL_PRIMARY" \
    || { echo 'Manual primary is not an available RDS primary candidate.' >&2; exit 2; }
  SOURCE_PRIMARY="$MANUAL_PRIMARY"
else
  primary_default=''
  if [[ "$FALLBACK" != true ]]; then
    for index in "${!candidate_ids[@]}"; do
      if [[ "${candidate_ids[$index]}" == "${BB3_SOURCE_PRIMARY_ID:-}" ]]; then
        primary_default="$((index+1))"
        break
      fi
    done
    if [[ -z "$primary_default" && ${#candidate_ids[@]} == 1 ]]; then primary_default=1; fi
  fi
  if ((${#candidate_ids[@]} == 0)); then
    echo "No available PostgreSQL primary matched the BB3 tags for $ENVIRONMENT." >&2
    exit 2
  elif [[ "$MODE" == print && -n "$primary_default" ]]; then
    SOURCE_PRIMARY="${candidate_ids[$((primary_default-1))]}"
  elif [[ "$MODE" == interactive && -t 0 && -t 1 ]]; then
    if [[ "$FALLBACK" == true ]]; then
      printf '%b\n' "${RED}Selectable primary candidates (fallback; verify before choosing):${RESET}"
      for index in "${!candidate_ids[@]}"; do printf '%b\n' "${RED}  $((index+1))) ${candidate_ids[$index]}${RESET}"; done
    else
      printf 'Primary RDS instances matching environment and app tags:\n'
      for index in "${!candidate_ids[@]}"; do
        if [[ "$((index+1))" == "$primary_default" ]]; then
          printf '%b\n' "${GREEN}  $((index+1))) ${candidate_ids[$index]} [default]${RESET}"
        else
          printf '  %d) %s\n' "$((index+1))" "${candidate_ids[$index]}"
        fi
      done
    fi
    if [[ -n "$primary_default" ]]; then
      bb3_prompt_read selection "Selection [$primary_default]: " </dev/tty
      selection="${selection:-$primary_default}"
    else
      bb3_prompt_read selection 'Selection (required): ' </dev/tty
      [[ -n "$selection" ]] || { echo 'A primary selection is required.' >&2; exit 2; }
    fi
    [[ "$selection" =~ ^[0-9]+$ ]] && ((selection>=1 && selection<=${#candidate_ids[@]})) \
      || { echo 'Invalid primary selection.' >&2; exit 2; }
    SOURCE_PRIMARY="${candidate_ids[$((selection-1))]}"
  else
    printf 'Found %s eligible primary candidates; run interactively or select one with --primary <id>.\n' "${#candidate_ids[@]}" >&2
    printf '%s\n' "${candidate_ids[@]}" >&2
    exit 2
  fi
fi
primary="$(awsx rds describe-db-instances --db-instance-identifier "$SOURCE_PRIMARY" --query 'DBInstances[0]' --output json)"
attached="$(jq -c '[.ReadReplicaDBInstanceIdentifiers[]? | split(":") | last]' <<<"$primary")"
replica_ids=()
while IFS= read -r replica_id; do
  [[ -n "$replica_id" ]] || continue
  replica="$(awsx rds describe-db-instances --db-instance-identifier "$replica_id" --query 'DBInstances[0]' --output json)"
  if [[ "$(jq -r '.DBInstanceStatus' <<<"$replica")" == available \
    && "$(jq -r '.ReadReplicaSourceDBInstanceIdentifier|split(":")|last' <<<"$replica")" == "$SOURCE_PRIMARY" ]]; then
    replica_ids+=("$replica_id")
  else
    printf 'Attached replica is not selectable (not available or source mismatch): %s\n' "$replica_id" >&2
  fi
done < <(jq -r '.[]' <<<"$attached")
SOURCE_REPLICA=''
if ((${#replica_ids[@]} > 0)); then
  if [[ -n "$MANUAL_REPLICA" ]]; then
    printf '%s\n' "${replica_ids[@]}" | grep -Fxq "$MANUAL_REPLICA" \
      || { echo 'Manual replica is not an available replica attached to the selected primary.' >&2; exit 2; }
    SOURCE_REPLICA="$MANUAL_REPLICA"
  elif [[ "$MODE" == print && ${#replica_ids[@]} == 1 ]]; then
    SOURCE_REPLICA="${replica_ids[0]}"
  elif [[ "$MODE" == interactive && -t 0 && -t 1 ]]; then
    replica_default=''
    for index in "${!replica_ids[@]}"; do
      if [[ "${replica_ids[$index]}" == "${BB3_SOURCE_REPLICA_ID:-}" ]]; then
        replica_default="$((index+1))"
        break
      fi
    done
    if [[ -z "$replica_default" && ${#replica_ids[@]} == 1 ]]; then replica_default=1; fi
    printf 'Available replicas attached to %s:\n' "$SOURCE_PRIMARY"
    for index in "${!replica_ids[@]}"; do
      if [[ "$((index+1))" == "$replica_default" ]]; then
        printf '%b\n' "${GREEN}  $((index+1))) ${replica_ids[$index]} [default]${RESET}"
      else
        printf '  %d) %s\n' "$((index+1))" "${replica_ids[$index]}"
      fi
    done
    if [[ -n "$replica_default" ]]; then
      bb3_prompt_read selection "Replica selection [$replica_default]: " </dev/tty
      selection="${selection:-$replica_default}"
    else
      bb3_prompt_read selection 'Replica selection (required): ' </dev/tty
      [[ -n "$selection" ]] || { echo 'A replica selection is required.' >&2; exit 2; }
    fi
    [[ "$selection" =~ ^[0-9]+$ ]] && ((selection>=1 && selection<=${#replica_ids[@]})) \
      || { echo 'Invalid replica selection.' >&2; exit 2; }
    SOURCE_REPLICA="${replica_ids[$((selection-1))]}"
  else
    printf 'Found %s available attached replicas; run interactively or select one with --replica <id>.\n' "${#replica_ids[@]}" >&2
    printf '%s\n' "${replica_ids[@]}" >&2
    exit 2
  fi
elif [[ -n "$MANUAL_REPLICA" ]]; then
  echo 'Manual replica is not an available replica attached to the selected primary.' >&2
  exit 2
elif [[ "$(jq -r 'length' <<<"$attached")" -gt 0 ]]; then
  echo 'The selected primary has attached replicas, but none is available for baseline capture.' >&2
  exit 2
fi
if [[ -n "$MANUAL_SNAPSHOT" ]]; then
  snapshot="$(awsx rds describe-db-snapshots --db-snapshot-identifier "$MANUAL_SNAPSHOT" --output json)"
  [[ "$(jq -r '.DBSnapshots|length' <<<"$snapshot")" == 1 && "$(jq -r '.DBSnapshots[0].Status' <<<"$snapshot")" == available \
    && "$(jq -r '.DBSnapshots[0].DBInstanceIdentifier' <<<"$snapshot")" == "$SOURCE_PRIMARY" ]] \
    || { echo 'Manual snapshot must be available and belong to the selected primary.' >&2; exit 2; }
  SNAPSHOT_ID="$MANUAL_SNAPSHOT"
  SNAPSHOT_TIME="$(jq -r '.DBSnapshots[0].SnapshotCreateTime' <<<"$snapshot")"
else
  snapshots="$(awsx rds describe-db-snapshots --db-instance-identifier "$SOURCE_PRIMARY" --snapshot-type automated --output json)"
  snapshot_rows="$(jq -r '[.DBSnapshots[]? | select(.Status=="available") | [.DBSnapshotIdentifier,.SnapshotCreateTime]] | sort_by(.[1]) | reverse[] | @tsv' <<<"$snapshots")"
  snapshot_ids=(); snapshot_times=()
  while IFS=$'\t' read -r snapshot_id snapshot_time; do
    [[ -n "$snapshot_id" ]] || continue
    snapshot_ids+=("$snapshot_id"); snapshot_times+=("$snapshot_time")
  done <<< "$snapshot_rows"
  SNAPSHOT_ID=''; SNAPSHOT_TIME=''
  if ((${#snapshot_ids[@]} > 0)); then
    if [[ "$MODE" == interactive && -t 0 && -t 1 ]]; then
      printf 'Available automated snapshots for %s (newest first):\n' "$SOURCE_PRIMARY"
      for index in "${!snapshot_ids[@]}"; do
        if ((index == 0)); then
          printf '%b\n' "${GREEN}  $((index+1))) ${snapshot_ids[$index]} (${snapshot_times[$index]}) [latest daily backup; default]${RESET}"
        else
          printf '  %d) %s (%s)\n' "$((index+1))" "${snapshot_ids[$index]}" "${snapshot_times[$index]}"
        fi
      done
      bb3_prompt_read selection 'Snapshot selection [1]: ' </dev/tty
      selection="${selection:-1}"
      [[ "$selection" =~ ^[0-9]+$ ]] && ((selection>=1 && selection<=${#snapshot_ids[@]})) \
        || { echo 'Invalid snapshot selection.' >&2; exit 2; }
      snapshot_index=$((selection-1))
    elif [[ "$MODE" == print ]]; then
      printf 'Available automated snapshots for %s (newest first):\n' "$SOURCE_PRIMARY"
      for index in "${!snapshot_ids[@]}"; do
        if ((index == 0)); then
          printf '  %d) %s (%s) [latest daily backup; default]\n' "$((index+1))" "${snapshot_ids[$index]}" "${snapshot_times[$index]}"
        else
          printf '  %d) %s (%s)\n' "$((index+1))" "${snapshot_ids[$index]}" "${snapshot_times[$index]}"
        fi
      done
      snapshot_index=0
    else
      snapshot_index=0
    fi
    SNAPSHOT_ID="${snapshot_ids[$snapshot_index]}"
    SNAPSHOT_TIME="${snapshot_times[$snapshot_index]}"
  fi
fi
if [[ -n "$SNAPSHOT_ID" && -z "$SNAPSHOT_TIME" ]]; then
  SNAPSHOT_TIME="$(awsx rds describe-db-snapshots --db-snapshot-identifier "$SNAPSHOT_ID" --query 'DBSnapshots[0].SnapshotCreateTime' --output text)"
fi
RESTORE_TARGET_PRIMARY=''; RESTORE_TARGET_REPLICA=''
if [[ -n "$SNAPSHOT_ID" ]]; then
  target_suffix="$(printf '%s' "$SNAPSHOT_ID" | shasum -a 256 | cut -c1-12)"
  saved_targets_in_use=false
  for target_id in "${BB3_RESTORE_TARGET_PRIMARY_ID:-}" "${BB3_RESTORE_TARGET_REPLICA_ID:-}"; do
    if [[ -n "$target_id" ]] && jq -e --arg id "$target_id" \
      'any(.DBInstances[]?; .DBInstanceIdentifier==$id)' <<<"$instance_json" >/dev/null; then
      saved_targets_in_use=true
    fi
  done
  if [[ "${BB3_SNAPSHOT_ID:-}" == "$SNAPSHOT_ID" && -n "${BB3_RESTORE_TARGET_PRIMARY_ID:-}" \
    && -n "${BB3_RESTORE_TARGET_REPLICA_ID:-}" && "$saved_targets_in_use" != true ]]; then
    RESTORE_TARGET_PRIMARY="$BB3_RESTORE_TARGET_PRIMARY_ID"
    RESTORE_TARGET_REPLICA="$BB3_RESTORE_TARGET_REPLICA_ID"
  else
    if [[ -n "${BB3_RESTORE_TARGET_PRIMARY_ID:-}${BB3_RESTORE_TARGET_REPLICA_ID:-}" || "$saved_targets_in_use" == true ]]; then
      target_suffix+="-$(date -u +%Y%m%d%H%M%S)"
    fi
    RESTORE_TARGET_PRIMARY="bb3-${ENVIRONMENT}-restore-${target_suffix}"
    RESTORE_TARGET_REPLICA="bb3-${ENVIRONMENT}-replica-${target_suffix}"
  fi
fi
DISCOVERED_AT="$(date -u +%FT%TZ)"
print_summary() {
  printf 'Environment: %s\nPrimary: %s\n' "$ENVIRONMENT" "$SOURCE_PRIMARY"
  if [[ -n "$SOURCE_REPLICA" ]]; then printf 'Replica: %s\n' "$SOURCE_REPLICA"; else printf '%s\n' 'Replica: not present'; fi
  if [[ -n "$SNAPSHOT_ID" ]]; then printf 'Snapshot candidate: %s (%s)\n' "$SNAPSHOT_ID" "$SNAPSHOT_TIME"; else printf '%s\n' 'No automated snapshot candidate; select a manual snapshot with --snapshot.'; fi
  if [[ -n "$RESTORE_TARGET_PRIMARY" ]]; then
    printf 'Default restore targets: %s (primary), %s (replica)\n' "$RESTORE_TARGET_PRIMARY" "$RESTORE_TARGET_REPLICA"
  fi
  printf 'Caller/account verified; discovered at %s. No secret values were read.\n' "$DISCOVERED_AT"
}
print_env() {
  printf 'export ENV=%q\n' "$ENVIRONMENT"
  printf 'export APP=%q\n' bb3
  printf 'export BB3_AWS_PROFILE=%q\n' "$PROFILE"
  printf 'export BB3_AWS_REGION=%q\n' "$REGION"
  printf 'export BB3_ACCOUNT_ID=%q\n' "$ACCOUNT"
  printf 'export BB3_SOURCE_PRIMARY_ID=%q\n' "$SOURCE_PRIMARY"
  printf 'export BB3_SOURCE_REPLICA_ID=%q\n' "$SOURCE_REPLICA"
  printf 'export BB3_SNAPSHOT_ID=%q\n' "$SNAPSHOT_ID"
  printf 'export BB3_SNAPSHOT_TIME=%q\n' "$SNAPSHOT_TIME"
  printf 'export BB3_RESTORE_TARGET_PRIMARY_ID=%q\n' "$RESTORE_TARGET_PRIMARY"
  printf 'export BB3_RESTORE_TARGET_REPLICA_ID=%q\n' "$RESTORE_TARGET_REPLICA"
  printf 'export BB3_DISCOVERED_AT=%q\n' "$DISCOVERED_AT"
  [[ -z "${BB3_DR_ID:-}" ]] || printf 'export BB3_DR_ID=%q\n' "$BB3_DR_ID"
  [[ -z "${BB3_T0_AT:-}" ]] || printf 'export BB3_T0_AT=%q\n' "$BB3_T0_AT"
  [[ -z "${BB3_T0_EVIDENCE_REF:-}" ]] || printf 'export BB3_T0_EVIDENCE_REF=%q\n' "$BB3_T0_EVIDENCE_REF"
  [[ -z "${BB3_T1_AT:-}" ]] || printf 'export BB3_T1_AT=%q\n' "$BB3_T1_AT"
  [[ -z "${BB3_T1_EVIDENCE_REF:-}" ]] || printf 'export BB3_T1_EVIDENCE_REF=%q\n' "$BB3_T1_EVIDENCE_REF"
  [[ -z "${BB3_SCENARIO:-}" ]] || printf 'export BB3_SCENARIO=%q\n' "$BB3_SCENARIO"
}
case "$MODE" in
  print) print_env ;;
  interactive)
    bb3_keys='AWS_PROFILE|AWS_REGION|ACCOUNT_ID|SOURCE_PRIMARY_ID|SOURCE_REPLICA_ID|SNAPSHOT_ID|SNAPSHOT_TIME|RESTORE_TARGET_PRIMARY_ID|RESTORE_TARGET_REPLICA_ID|DISCOVERED_AT|DR_ID|T0_AT|T0_EVIDENCE_REF|T1_AT|T1_EVIDENCE_REF|SCENARIO'
    if [[ "${ENV:-}" == "$ENVIRONMENT" \
      && "${APP:-}" == bb3 \
      && "${BB3_AWS_PROFILE:-}" == "$PROFILE" \
      && "${BB3_AWS_REGION:-}" == "$REGION" \
      && "${BB3_ACCOUNT_ID:-}" == "$ACCOUNT" \
      && "${BB3_SOURCE_PRIMARY_ID:-}" == "$SOURCE_PRIMARY" \
      && "${BB3_SOURCE_REPLICA_ID:-}" == "$SOURCE_REPLICA" \
      && "${BB3_SNAPSHOT_ID:-}" == "$SNAPSHOT_ID" \
      && "${BB3_SNAPSHOT_TIME:-}" == "$SNAPSHOT_TIME" \
      && "${BB3_RESTORE_TARGET_PRIMARY_ID:-}" == "$RESTORE_TARGET_PRIMARY" \
      && "${BB3_RESTORE_TARGET_REPLICA_ID:-}" == "$RESTORE_TARGET_REPLICA" ]]; then
      printf 'Saved BB3 discovery selections already match; no changes needed. File: %s\n' "$ENV_FILE"
      exit 0
    fi
    [[ -t 0 && -t 1 ]] || { echo 'Interactive discovery requires a terminal; use --print to review non-interactively.' >&2; exit 2; }
    print_summary
    answer=''
    bb3_prompt_read answer 'Write these selections to iac/sandbox.env? [Y/n]: ' </dev/tty
    case "${answer,,}" in
      ''|y|yes) ;;
      n|no) echo 'No changes made to sandbox.env.'; exit 0 ;;
      *) echo 'Please answer Y or N; no changes made.' >&2; exit 2 ;;
    esac
    temp_file="$(mktemp "${ENV_FILE}.tmp.XXXXXX")"
    trap 'rm -f "$temp_file"' EXIT
    awk -v keys="$bb3_keys" \
      '$0 !~ "^export BB3_ENV=" && $0 !~ "^export (ENV|APP)=" && $0 !~ "^export BB3_(" keys ")="' \
      "$ENV_FILE" > "$temp_file"
    print_env >> "$temp_file"
    chmod 600 "$temp_file"
    mv -f "$temp_file" "$ENV_FILE"
    trap - EXIT
    printf 'Wrote source-selection inputs to ignored file: %s\n' "$ENV_FILE"
    ;;
esac