#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bb3-prompt.sh
source "$HERE/bb3-prompt.sh"
ROOT="$(cd "$HERE/../../.." && pwd)"
CONFIG="$ROOT/iac/sandbox.env"
LEDGER="${BB3_LEDGER_DIR:-$ROOT/evidence/bb3-secret-endpoints}"
RUN_SELECTION=latest
FAILBACK=false
if [[ $# -gt 0 ]]; then
  if [[ $# == 2 && "$1" == --failback && "$2" =~ ^DR-[A-Za-z0-9_-]{1,120}$ ]]; then
    FAILBACK=true
    RUN_SELECTION="$2"
  elif [[ $# == 2 && "$1" == --run-id ]]; then
    RUN_SELECTION="$2"
  else
    echo 'Usage: app-deploy-confirm.sh [--run-id DR-ID | --failback DR-ID]' >&2
    exit 2
  fi
fi
git -C "$ROOT" check-ignore -q "$LEDGER/check.json" \
  || { echo 'App deployment attestations must be Git-ignored.' >&2; exit 2; }
[[ -t 0 ]] || { echo 'Run this step in an interactive terminal.' >&2; exit 2; }
ulimit -c 0
if [[ "$FAILBACK" == true ]]; then
  RUN="$(python3 "$HERE/secret-endpoints.py" --show-failback "$LEDGER" "$RUN_SELECTION")"
  RUN_ID="$RUN_SELECTION"
  ACCOUNT="$(jq -er '.account' <<< "$RUN")"
  REGION="$(jq -er '.region' <<< "$RUN")"
else
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
  RUN="$(python3 "$HERE/secret-endpoints.py" --show-run "$LEDGER" "$RUN_SELECTION" "$ACCOUNT" "$REGION")"
  RUN_ID="$(jq -er '.runId' <<< "$RUN")"
  FENCE="$LEDGER/$RUN_ID/fence.json"
  python3 "$HERE/secret-endpoints.py" --check-fence "$FENCE" "$RUN_ID" "$ACCOUNT" "$REGION" \
    "$(jq -er '.source_db' <<< "$RUN")" "$(jq -r '.source_replica // empty' <<< "$RUN")" \
    "$(jq -er '.db' <<< "$RUN")" "$(jq -r '.replica // empty' <<< "$RUN")" \
    || { echo 'P3-S01 verified fence and session-closure confirmation are required before app deployment.' >&2; exit 2; }
fi
PRIMARY_HOST="$(jq -er '.primaryHost // .newHost' <<< "$RUN")"
REPLICA_HOST="$(jq -er '.replicaHost // .newReplicaHost' <<< "$RUN")"
printf 'DR run: %s\nPrimary: %s\nReplica: %s\n' "$RUN_ID" "$PRIMARY_HOST" "$REPLICA_HOST"
printf 'Deployment mode:\n  1. Automatic deployment script (unavailable; no action will run)\n  2. Manual deployment already completed\n'
bb3_prompt_read DEPLOY_MODE 'Select 1 or 2: '
case "$DEPLOY_MODE" in
  1)
    echo 'Automatic BB3 application deployment is unavailable. No deployment was run or recorded.' >&2
    exit 2
    ;;
  2) ;;
  *) echo 'Invalid deployment mode.' >&2; exit 2 ;;
esac
if [[ "$FAILBACK" == true ]]; then
  SAVED_OWNER="$(jq -er '.failbackFence.appOwner' <<< "$RUN")"
  bb3_prompt_read APP_OWNER "App owner name [${SAVED_OWNER}]: "
  APP_OWNER="${APP_OWNER:-$SAVED_OWNER}"
else
  bb3_prompt_read APP_OWNER 'App owner name: '
fi
[[ -n "$APP_OWNER" ]] || { echo 'App owner is required.' >&2; exit 2; }
RUN_DIR="$LEDGER/$RUN_ID"
DEPLOY_LOG="$RUN_DIR/app-deploy.log"
DEPLOY_RECORD="$RUN_DIR/app-deploy.json"
DEPLOY_FLAG=--record-app-deploy
LOG_NAME=app-deploy.log
if [[ "$FAILBACK" == true ]]; then
  DEPLOY_LOG="$RUN_DIR/failback-app-deploy.log"
  DEPLOY_RECORD="$RUN_DIR/failback-app-deploy.json"
  DEPLOY_FLAG=--record-failback-app-deploy
  LOG_NAME=failback-app-deploy.log
fi
EVIDENCE_REF="evidence/bb3-secret-endpoints/$RUN_ID/$LOG_NAME"
[[ ! -e "$DEPLOY_RECORD" ]] \
  || { echo 'A deployment attestation already exists for this run.' >&2; exit 2; }
mkdir -p "$RUN_DIR"
chmod 700 "$LEDGER" "$RUN_DIR"
git -C "$ROOT" check-ignore -q "$DEPLOY_LOG" \
  || { echo 'Deployment log capture must be Git-ignored.' >&2; exit 2; }
if [[ -e "$DEPLOY_LOG" || -L "$DEPLOY_LOG" ]]; then
  [[ -f "$DEPLOY_LOG" && ! -L "$DEPLOY_LOG" && -s "$DEPLOY_LOG" ]] \
    || { echo 'Existing deployment log is not a nonempty regular file; refusing to replace it.' >&2; exit 2; }
  printf 'Reusing existing sanitized deployment log for owner review: %s\n' "$EVIDENCE_REF"
else
  TMP_LOG="$(mktemp "$RUN_DIR/.$LOG_NAME.XXXXXX")"
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
  printf 'Captured sanitized deployment log; evidence=%s\n' "$EVIDENCE_REF"
fi
if [[ "$FAILBACK" == true ]]; then
  bb3_prompt_read CONFIRM 'Owner confirms both original endpoints and all expected services/tasks converged? [y/N]: '
else
  bb3_prompt_read CONFIRM 'Owner confirms both restored endpoints and all expected services/tasks converged? [y/N]: '
fi
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo 'Deployment confirmation not recorded; sanitized log retained for review.' >&2; exit 2; }
RESULT="$(python3 "$HERE/secret-endpoints.py" "$DEPLOY_FLAG" "$LEDGER" "$RUN_ID" "$ACCOUNT" "$REGION" "$APP_OWNER" "$EVIDENCE_REF")"
jq '{runId,mode,status,appOwner,evidenceRef,servicesConverged,primaryHost,replicaHost,recordedAt}' <<< "$RESULT"
if [[ "$FAILBACK" == true ]]; then
  echo 'Failback app deployment/convergence recorded as supplemental local evidence. Continue with P4-S01/P4-S02 --failback for the original DB pair.'
else
  echo 'Deployment attestation recorded. Run P4-S01 after the app DB health check to record T8, then P4-S02 after the business transaction/readback to record T9.'
fi
