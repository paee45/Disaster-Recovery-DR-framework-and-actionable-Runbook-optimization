#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
CONFIG="$ROOT/iac/sandbox.env"
LEDGER="$ROOT/evidence/bb3-secret-endpoints"
RUN_SELECTION=latest
if [[ $# -gt 0 ]]; then
  [[ $# == 2 && "$1" == --run-id ]] || { echo 'Usage: app-deploy-confirm.sh [--run-id DR-ID]' >&2; exit 2; }
  RUN_SELECTION="$2"
fi
[[ -f "$CONFIG" ]] || { echo 'Missing ignored iac/sandbox.env.' >&2; exit 2; }
# shellcheck source=/dev/null
source "$CONFIG"
unset AWS_DEFAULT_PROFILE TF_VAR_terrakube_token
PROFILE="${TF_VAR_aws_profile:-}"
REGION="${TF_VAR_region:-}"
ACCOUNT="${TF_VAR_account_id:-}"
[[ "$PROFILE" =~ ^(lab_sandbox|pa_aws_sandbox|pa_iam_aws_sandbox)$ \
  && "$REGION" == ap-southeast-1 && "$ACCOUNT" =~ ^[0-9]{12}$ \
  && "${ENV:-}" =~ ^(dev|uat)$ ]] || { echo 'Only dev/uat sandbox is allowed.' >&2; exit 2; }
[[ -z "${AWS_ACCESS_KEY_ID:-}${AWS_SECRET_ACCESS_KEY:-}${AWS_SESSION_TOKEN:-}" ]] \
  || { echo 'Unset exported AWS credentials.' >&2; exit 2; }
CALLER="$(aws --profile "$PROFILE" --region "$REGION" --no-cli-pager sts get-caller-identity --query Account --output text)"
[[ "$CALLER" == "$ACCOUNT" ]] || { echo 'AWS caller does not match the configured sandbox.' >&2; exit 2; }
git -C "$ROOT" check-ignore -q "$LEDGER/check.json" \
  || { echo 'App deployment attestations must be Git-ignored.' >&2; exit 2; }
[[ -t 0 ]] || { echo 'Run this step in an interactive terminal.' >&2; exit 2; }
ulimit -c 0
RUN="$(python3 "$HERE/secret-endpoints.py" --show-run "$LEDGER" "$RUN_SELECTION" "$ACCOUNT" "$REGION")"
RUN_ID="$(jq -er '.runId' <<< "$RUN")"
FENCE="$LEDGER/$RUN_ID/fence.json"
python3 "$HERE/secret-endpoints.py" --check-fence "$FENCE" "$RUN_ID" "$ACCOUNT" "$REGION" \
  "$(jq -er '.source_db' <<< "$RUN")" "$(jq -r '.source_replica // empty' <<< "$RUN")" \
  "$(jq -er '.db' <<< "$RUN")" "$(jq -r '.replica // empty' <<< "$RUN")" \
  || { echo 'P3-S01 verified fence and session-closure confirmation are required before app deployment.' >&2; exit 2; }
printf 'DR run: %s\nRestored primary: %s\nNew replica: %s\n' \
  "$RUN_ID" "$(jq -er '.newHost' <<< "$RUN")" "$(jq -er '.newReplicaHost' <<< "$RUN")"
printf 'Deployment mode:\n  1. Automatic deployment script (not implemented or tested)\n  2. Manual deployment already completed\n'
read -r -p 'Select 1 or 2: ' DEPLOY_MODE
case "$DEPLOY_MODE" in
  1)
    echo 'Automatic BB3 application deployment is not implemented. No deployment was run or recorded.' >&2
    exit 2
    ;;
  2) ;;
  *) echo 'Invalid deployment mode.' >&2; exit 2 ;;
esac
read -r -p 'App owner name: ' APP_OWNER
[[ -n "$APP_OWNER" ]] || { echo 'App owner is required.' >&2; exit 2; }
RUN_DIR="$LEDGER/$RUN_ID"
DEPLOY_LOG="$RUN_DIR/app-deploy.log"
[[ ! -e "$DEPLOY_LOG" ]] || { echo 'A deployment log capture already exists for this run.' >&2; exit 2; }
mkdir -p "$RUN_DIR"
chmod 700 "$LEDGER" "$RUN_DIR"
git -C "$ROOT" check-ignore -q "$DEPLOY_LOG" \
  || { echo 'Deployment log capture must be Git-ignored.' >&2; exit 2; }
TMP_LOG="$(mktemp "$RUN_DIR/.app-deploy-log.XXXXXX")"
trap 'rm -f "$TMP_LOG"' EXIT
echo 'Paste sanitized deployment/convergence logs. Redact credentials, tokens, secret values, and customer data.'
echo 'Paste the full log, then press Enter twice on a blank line to finish.'
LOG_COMPLETE=false
BLANK_PENDING=false
while IFS= read -r LOG_LINE; do
  if [[ -z "$LOG_LINE" ]]; then
    if [[ "$BLANK_PENDING" == true ]]; then
      LOG_COMPLETE=true
      break
    fi
    BLANK_PENDING=true
    continue
  fi
  if [[ "$BLANK_PENDING" == true ]]; then
    printf '\n' >> "$TMP_LOG"
    BLANK_PENDING=false
  fi
  printf '%s\n' "$LOG_LINE" >> "$TMP_LOG"
done </dev/tty
[[ "$LOG_COMPLETE" == true && -s "$TMP_LOG" ]] \
  || { echo 'Deployment log capture was incomplete or empty.' >&2; exit 2; }
chmod 600 "$TMP_LOG"
mv "$TMP_LOG" "$DEPLOY_LOG"
trap - EXIT
EVIDENCE_REF="evidence/bb3-secret-endpoints/$RUN_ID/app-deploy.log"
printf 'Captured sanitized deployment log; evidence=%s\n' "$EVIDENCE_REF"
read -r -p 'Owner confirms both restored endpoints and all expected services/tasks converged? [y/N]: ' CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo 'Deployment confirmation not recorded; sanitized log retained for review.' >&2; exit 2; }
RESULT="$(python3 "$HERE/secret-endpoints.py" --record-app-deploy "$LEDGER" "$RUN_ID" "$ACCOUNT" "$REGION" "$APP_OWNER" "$EVIDENCE_REF")"
jq '{runId,mode,status,appOwner,evidenceRef,servicesConverged,primaryHost,replicaHost,recordedAt}' <<< "$RESULT"
echo 'Deployment attestation recorded. Run P4-S01 after the app DB health check to record T8, then P4-S02 after the business transaction/readback to record T9.'
