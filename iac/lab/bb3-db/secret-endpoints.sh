#!/usr/bin/env bash
set -euo pipefail
set +x

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
CONFIG="${BB3_SECRET_CONFIG:-$ROOT/iac/sandbox.env}"
APPLY=false
case "${1:---preview}" in
  --preview) ;;
  --apply) APPLY=true ;;
  *) echo 'Usage: secret-endpoints.sh [--preview|--apply]' >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || exit 2
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
for variable in BB3_SOURCE_PRIMARY_ID BB3_SOURCE_REPLICA_ID BB3_RESTORE_TARGET_PRIMARY_ID BB3_RESTORE_TARGET_REPLICA_ID; do
  [[ -n "${!variable:-}" ]] || { echo "Missing $variable; discover and validate both database pairs first." >&2; exit 2; }
done
[[ -t 0 ]] || { echo 'Use an interactive terminal; never supply a password here.' >&2; exit 2; }
SECRETS="$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" --no-cli-pager secretsmanager list-secrets \
  --query 'SecretList[].{Name:Name}' --output json)"
HIGHLIGHT=''
SELECTED_COLOR=''
RESET=''
if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != dumb ]]; then
  HIGHLIGHT=$'\033[1;36m'
  SELECTED_COLOR=$'\033[1;32m'
  RESET=$'\033[0m'
fi
SECRET_COUNT="$(jq -er 'length' <<< "$SECRETS")"
[[ "$SECRET_COUNT" -gt 0 ]] || { echo 'No AWS secrets found. Nothing selected or changed.' >&2; exit 2; }
printf 'AWS secret names (%s found):\n' "$SECRET_COUNT"
SECRET_NUMBER=0
while IFS= read -r name; do
  SECRET_NUMBER=$((SECRET_NUMBER + 1))
  printf '  %2d. %s%s%s\n' "$SECRET_NUMBER" "$HIGHLIGHT" "$name" "$RESET"
done < <(jq -r 'sort_by(.Name) | .[].Name' <<< "$SECRETS")
echo 'Select a number or enter the approved secret NAME/full ARN, NOT its password or value.'
read -r -p 'Secret selection: ' SECRET_ID
[[ -n "$SECRET_ID" ]] || { echo 'No secret selected.' >&2; exit 2; }
if [[ "$SECRET_ID" =~ ^[0-9]+$ ]]; then
  SECRET_ID="$(jq -er --arg index "$SECRET_ID" \
    'sort_by(.Name) | if ($index|tonumber) > 0 then .[($index|tonumber)-1].Name // error("Invalid secret number") else error("Invalid secret number") end' <<< "$SECRETS")"
fi
META="$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" --no-cli-pager secretsmanager describe-secret \
  --secret-id "$SECRET_ID" --query '{Name:Name,ARN:ARN}' --output json)"
SECRET_NAME="$(jq -er '.Name' <<< "$META")"
SECRET_ARN="$(jq -er '.ARN' <<< "$META")"
[[ "$SECRET_ARN" == "arn:aws:secretsmanager:$AWS_REGION:$ACCOUNT:secret:"* ]] \
  || { echo 'Secret is outside the configured sandbox region/account.' >&2; exit 2; }
printf 'Selected AWS secret name: %s%s%s\n' "$SELECTED_COLOR" "$SECRET_NAME" "$RESET"
read -r -p 'Confirm the EXACT secret name or full ARN before endpoint validation: ' CONFIRMED
[[ "$CONFIRMED" == "$SECRET_NAME" || "$CONFIRMED" == "$SECRET_ARN" ]] \
  || { echo 'Secret confirmation did not match. Nothing changed.' >&2; exit 2; }

run_update() {
  python3 "$HERE/secret-endpoints.py" "$AWS_PROFILE" "$AWS_REGION" "$SECRET_ARN" "$CONFIRMED" \
    "$1" "$2" "$BB3_SOURCE_PRIMARY_ID" "$BB3_SOURCE_REPLICA_ID" \
    "$BB3_RESTORE_TARGET_PRIMARY_ID" "$BB3_RESTORE_TARGET_REPLICA_ID"
}

echo 'Approved sandbox custodian mode: the local script handles the full JSON in memory, without printing it or writing payload files.'
PREVIEW="$(run_update false '')"
jq '{secretName,previousVersion,oldHost,newHost,oldReplicaHost,newReplicaHost,applied}' <<< "$PREVIEW"
echo 'Both current endpoint keys match the old primary/replica. This does not verify passwords or application access.'
if [[ "$APPLY" == false ]]; then
  echo 'Preview only. Nothing changed. Run with --apply for a fresh preview and explicit approval.'
  exit 0
fi
printf 'Only DB_HOST and DB_REPLICA_HOST will change. DB credentials and unrelated fields will be preserved.\n'
read -r -p 'App owner approved sandbox-only endpoint cutover? Type UPDATE-ENDPOINTS to apply: ' APPROVAL
[[ "$APPROVAL" == UPDATE-ENDPOINTS ]] || { echo 'Not approved. Nothing changed.' >&2; exit 2; }
RESULT="$(run_update true "$(jq -er '.previousVersion' <<< "$PREVIEW")")"
jq -e '.applied == true' <<< "$RESULT" >/dev/null
jq '{secretName,previousVersion,newVersion,newHost,newReplicaHost,applied,unchangedFieldsVerified}' <<< "$RESULT"
echo 'Secret endpoints updated only. No deployment, fencing, password check, or business E2E was performed.'