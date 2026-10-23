#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bb3-prompt.sh
source "$HERE/bb3-prompt.sh"
ROOT="$(cd "$HERE/../../.." && pwd)"
CONFIG="${BB3_SECRET_CONFIG:-$ROOT/iac/sandbox.env}"
APPLY=false
OPERATION=cutover
MODE=auto
RUN_SELECTION=latest
SUGGESTED_RUN=''
SAVED_SECRET_NAME=''
LEDGER_DIR="$ROOT/evidence/bb3-secret-endpoints"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --preview) APPLY=false; shift ;;
    --apply) APPLY=true; shift ;;
    --run-id)
      [[ $# -ge 2 ]] || exit 2
      SUGGESTED_RUN="$2"; shift 2 ;;
    --failback)
      OPERATION=failback; shift
      if [[ $# -gt 0 && "$1" != --* ]]; then RUN_SELECTION="$1"; shift; fi ;;
    *) echo 'Usage: secret-endpoints.sh [--preview|--apply] [--run-id DR-ID] [--failback [DR-ID|latest]]' >&2; exit 2 ;;
  esac
done
[[ -z "${AWS_ACCESS_KEY_ID:-}${AWS_SECRET_ACCESS_KEY:-}${AWS_SESSION_TOKEN:-}" ]] \
  || { echo 'Unset exported AWS credentials before using the sandbox profile.' >&2; exit 2; }
[[ -f "$CONFIG" ]] || { echo 'Missing ignored sandbox configuration.' >&2; exit 2; }
# shellcheck source=/dev/null
source "$CONFIG"
unset AWS_DEFAULT_PROFILE TF_VAR_terrakube_token
AWS_PROFILE="${TF_VAR_aws_profile:-}"
AWS_REGION="${TF_VAR_region:-}"
ACCOUNT="${TF_VAR_account_id:-}"
[[ "$AWS_PROFILE" =~ ^(lab_sandbox|pa_aws_sandbox|pa_iam_aws_sandbox)$ \
  && "$AWS_REGION" == ap-southeast-1 && "$ACCOUNT" =~ ^[0-9]{12}$ \
  && "${ENV:-}" =~ ^(dev|uat)$ ]] \
  || { echo 'Only the configured dev/uat sandbox is supported.' >&2; exit 2; }
CALLER="$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" --no-cli-pager sts get-caller-identity --query Account --output text)"
[[ "$CALLER" == "$ACCOUNT" ]] || { echo 'Wrong sandbox account.' >&2; exit 2; }
HISTORY="$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" configure get cli_history || true)"
[[ "$HISTORY" != enabled ]] || { echo 'AWS CLI history is enabled. Disable it before handling secret values.' >&2; exit 2; }
ulimit -c 0
git -C "$ROOT" check-ignore -q "$LEDGER_DIR/check.json" \
  || { echo 'Endpoint records must be Git-ignored.' >&2; exit 2; }
[[ -t 0 ]] || { echo 'Use an interactive terminal; never supply a password here.' >&2; exit 2; }
if [[ "$OPERATION" == failback ]]; then
  SAVED="$(python3 "$HERE/secret-endpoints.py" --show-run "$LEDGER_DIR" "$RUN_SELECTION" "$ACCOUNT" "$AWS_REGION")"
  SUGGESTED_RUN="$(jq -er '.runId' <<< "$SAVED")"
  SAVED_SECRET_NAME="$(jq -er '.secretName' <<< "$SAVED")"
  BB3_SOURCE_PRIMARY_ID="$(jq -er '.db' <<< "$SAVED")"
  BB3_SOURCE_REPLICA_ID="$(jq -er '.replica' <<< "$SAVED")"
  BB3_RESTORE_TARGET_PRIMARY_ID="$(jq -er '.source_db' <<< "$SAVED")"
  BB3_RESTORE_TARGET_REPLICA_ID="$(jq -er '.source_replica' <<< "$SAVED")"
  echo 'Saved cutover selected for secret-only failback (verify this is the intended run):'
  jq '{runId,secretName,previousVersion,newVersion,oldHost,oldReplicaHost,newHost,newReplicaHost}' <<< "$SAVED"
fi
for variable in BB3_SOURCE_PRIMARY_ID BB3_SOURCE_REPLICA_ID BB3_RESTORE_TARGET_PRIMARY_ID BB3_RESTORE_TARGET_REPLICA_ID; do
  [[ -n "${!variable:-}" ]] || { echo "Missing $variable; discover and validate both database pairs first." >&2; exit 2; }
done
if [[ "$OPERATION" == failback ]]; then
  SECRET_ID="$SAVED_SECRET_NAME"
else
  SECRETS="$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" --no-cli-pager secretsmanager list-secrets \
    --query 'SecretList[].{Name:Name}' --output json)"
fi
HIGHLIGHT=''
SELECTED_COLOR=''
RESET=''
if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != dumb ]]; then
  HIGHLIGHT=$'\033[1;36m'
  SELECTED_COLOR=$'\033[1;32m'
  RESET=$'\033[0m'
fi
if [[ "$OPERATION" == failback ]]; then
  printf 'Reusing secret from the saved cutover for failback: %s\n' "$SECRET_ID"
else
  SECRET_COUNT="$(jq -er 'length' <<< "$SECRETS")"
  [[ "$SECRET_COUNT" -gt 0 ]] || { echo 'No AWS secrets found. Nothing selected or changed.' >&2; exit 2; }
  printf 'AWS secret names (%s found):\n' "$SECRET_COUNT"
  SECRET_NUMBER=0
  while IFS= read -r name; do
    SECRET_NUMBER=$((SECRET_NUMBER + 1))
    printf '  %2d. %s%s%s\n' "$SECRET_NUMBER" "$HIGHLIGHT" "$name" "$RESET"
  done < <(jq -r 'sort_by(.Name) | .[].Name' <<< "$SECRETS")
  echo 'Select a number or enter the approved secret NAME/full ARN, NOT its password or value.'
  bb3_prompt_read SECRET_ID 'Secret selection: '
  [[ -n "$SECRET_ID" ]] || { echo 'No secret selected.' >&2; exit 2; }
  if [[ "$SECRET_ID" =~ ^[0-9]+$ ]]; then
    SECRET_ID="$(jq -er --arg index "$SECRET_ID" \
      'sort_by(.Name) | if ($index|tonumber) > 0 then .[($index|tonumber)-1].Name // error("Invalid secret number") else error("Invalid secret number") end' <<< "$SECRETS")"
  fi
fi
META="$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" --no-cli-pager secretsmanager describe-secret \
  --secret-id "$SECRET_ID" --query '{Name:Name,ARN:ARN}' --output json)"
SECRET_NAME="$(jq -er '.Name' <<< "$META")"
SECRET_ARN="$(jq -er '.ARN' <<< "$META")"
[[ "$SECRET_ARN" == "arn:aws:secretsmanager:$AWS_REGION:$ACCOUNT:secret:"* ]] \
  || { echo 'Secret is outside the configured sandbox region/account.' >&2; exit 2; }
printf 'Selected AWS secret name: %s%s%s\n' "$SELECTED_COLOR" "$SECRET_NAME" "$RESET"
CONFIRMED="$SECRET_NAME"
if [[ -z "$SUGGESTED_RUN" ]]; then
  TARGET_ARN="$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" --no-cli-pager rds describe-db-instances \
    --db-instance-identifier "$BB3_RESTORE_TARGET_PRIMARY_ID" --query 'DBInstances[0].DBInstanceArn' --output text)"
  SUGGESTED_RUN="$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" --no-cli-pager rds list-tags-for-resource \
    --resource-name "$TARGET_ARN" --query 'TagList[?Key==`dr-restore`].Value | [0]' --output text)"
  [[ "$SUGGESTED_RUN" != None ]] || SUGGESTED_RUN=''
fi
if [[ "$OPERATION" == failback ]]; then
  RUN_ID="$SUGGESTED_RUN"
  printf 'Reusing saved failback run ID: %s\n' "$RUN_ID"
else
  bb3_prompt_read RUN_ID "Confirm DR run ID [${SUGGESTED_RUN:-no default}]: "
  RUN_ID="${RUN_ID:-$SUGGESTED_RUN}"
fi
[[ "$RUN_ID" =~ ^DR-[A-Za-z0-9_-]{1,120}$ ]] || { echo 'Invalid or missing DR run ID.' >&2; exit 2; }
if [[ -n "$SUGGESTED_RUN" && "$RUN_ID" != "$SUGGESTED_RUN" ]]; then
  echo 'Confirmed DR run ID does not match the restored primary dr-restore tag or selected saved run.' >&2
  exit 2
fi
printf 'DR run: %s; operation: %s; record directory: %s/%s\n' "$RUN_ID" "$OPERATION" "$LEDGER_DIR" "$RUN_ID"
if [[ "$OPERATION" == cutover ]]; then
  printf 'Secret update mode:\n  1. Automatic AWS CLI endpoint update\n  2. Manual update already performed; verify only\n'
  bb3_prompt_read MODE_SELECTION 'Select 1 or 2: '
  case "$MODE_SELECTION" in
    1) MODE=auto ;;
    2) MODE=manual ;;
    *) echo 'Invalid secret-update mode.' >&2; exit 2 ;;
  esac
fi

run_update() {
  python3 "$HERE/secret-endpoints.py" "$AWS_PROFILE" "$AWS_REGION" "$SECRET_ARN" "$CONFIRMED" \
    "$1" "$2" "$BB3_SOURCE_PRIMARY_ID" "$BB3_SOURCE_REPLICA_ID" \
    "$BB3_RESTORE_TARGET_PRIMARY_ID" "$BB3_RESTORE_TARGET_REPLICA_ID" \
    "$ACCOUNT" "$RUN_ID" "$LEDGER_DIR" "$OPERATION" "$MODE"
}

show_endpoint_plan() {
  local preview="$1" destination='REPLACE WITH'
  local current='CURRENT'
  [[ "$OPERATION" != failback ]] || destination='RETURN TO'
  if [[ "$MODE" == manual ]]; then
    destination='VERIFIED TARGET'
    current='SECRET NOW'
  fi
  printf '\n%-17s %-14s %s\n' 'SECRET KEY' 'CHANGE' 'HOST VALUE'
  printf '%-17s %-14s %s%s%s\n' 'DB_HOST' "$current" "$HIGHLIGHT" "$(jq -er '.oldHost' <<< "$preview")" "$RESET"
  printf '%-17s %-14s %s%s%s\n' 'DB_HOST' "$destination" "$SELECTED_COLOR" "$(jq -er '.newHost' <<< "$preview")" "$RESET"
  printf '\n'
  printf '%-17s %-14s %s%s%s\n' 'DB_REPLICA_HOST' "$current" "$HIGHLIGHT" "$(jq -er '.oldReplicaHost' <<< "$preview")" "$RESET"
  printf '%-17s %-14s %s%s%s\n' 'DB_REPLICA_HOST' "$destination" "$SELECTED_COLOR" "$(jq -er '.newReplicaHost' <<< "$preview")" "$RESET"
  printf '\n'
}

echo 'Approved sandbox custodian mode: the local script handles the full JSON in memory, without printing it or writing payload files.'
PREVIEW="$(run_update false '' "$MODE")"
jq '{runId,operation,secretName,previousVersion,applied}' <<< "$PREVIEW"
show_endpoint_plan "$PREVIEW"
if [[ "$MODE" == manual ]]; then
  echo 'Manual verification reads the current secret in memory and does not write to AWS.'
else
  echo 'Both current endpoint keys match the expected source primary/replica.'
fi
if [[ "$APPLY" == false ]]; then
  echo 'Preview only. Nothing changed. Run with --apply for a fresh check and confirmation.'
  exit 0
fi
FENCE_FILE="$LEDGER_DIR/$RUN_ID/fence.json"
[[ "$OPERATION" != failback ]] || FENCE_FILE="$LEDGER_DIR/$RUN_ID/failback-fence.json"
python3 "$HERE/secret-endpoints.py" --check-fence "$FENCE_FILE" "$RUN_ID" "$ACCOUNT" "$AWS_REGION" \
  "$BB3_SOURCE_PRIMARY_ID" "$BB3_SOURCE_REPLICA_ID" \
  "$BB3_RESTORE_TARGET_PRIMARY_ID" "$BB3_RESTORE_TARGET_REPLICA_ID" \
  || { echo "No matching fence record with verified isolation and session closure at $FENCE_FILE. No secret write made." >&2; exit 2; }
if [[ "$MODE" == manual ]]; then
  bb3_prompt_token_read APPROVAL \
    'Have you manually updated both secret hosts to the displayed targets? Type ' \
    ENDPOINTS-ALREADY-UPDATED ': '
  [[ "$APPROVAL" == ENDPOINTS-ALREADY-UPDATED ]] || { echo 'Not confirmed. No AWS value changed.' >&2; exit 2; }
  RESULT="$(run_update true '' manual)"
  jq -e '.manualVerified == true' <<< "$RESULT" >/dev/null
  jq '{runId,operation,mode,secretName,newVersion,manualVerified}' <<< "$RESULT"
  echo 'Manual endpoint values verified and journal recorded. No AWS secret write occurred.'
  exit 0
fi
printf 'Only DB_HOST and DB_REPLICA_HOST will change. DB credentials and unrelated fields will be preserved.\n'
TOKEN=UPDATE-ENDPOINTS
if [[ "$OPERATION" == failback ]]; then
  TOKEN=FAILBACK-ENDPOINTS
  echo 'Confirm the displayed CURRENT and RETURN-TO host values. Secret-only failback does not reconcile data or restart applications.'
fi
bb3_prompt_token_read APPROVAL "Authorized sandbox $OPERATION of this secret? Type " "$TOKEN" ' to apply: '
[[ "$APPROVAL" == "$TOKEN" ]] || { echo 'Not approved. Nothing changed.' >&2; exit 2; }
RESULT="$(run_update true "$(jq -er '.previousVersion' <<< "$PREVIEW")")"
jq -e '.applied == true' <<< "$RESULT" >/dev/null
jq '{runId,operation,secretName,previousVersion,newVersion,newHost,newReplicaHost,applied,unchangedFieldsVerified}' <<< "$RESULT"
echo 'Secret endpoints updated only. No deployment, fencing, password check, or business E2E was performed.'