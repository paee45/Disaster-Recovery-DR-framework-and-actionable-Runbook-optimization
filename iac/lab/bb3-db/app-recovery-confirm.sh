#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
CONFIG="$ROOT/iac/sandbox.env"
LEDGER="$ROOT/evidence/bb3-secret-endpoints"
MODE=''
RUN_SELECTION=latest
[[ $# -ge 1 ]] || { echo 'Usage: app-recovery-confirm.sh <connectivity|e2e> [--run-id DR-ID]' >&2; exit 2; }
MODE="$1"; shift
[[ "$MODE" =~ ^(connectivity|e2e)$ ]] || { echo 'Mode must be connectivity or e2e.' >&2; exit 2; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) [[ $# -ge 2 ]] || exit 2; RUN_SELECTION="$2"; shift 2 ;;
    *) echo 'Usage: app-recovery-confirm.sh <connectivity|e2e> [--run-id DR-ID]' >&2; exit 2 ;;
  esac
done
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
  || { echo 'App recovery records must be Git-ignored.' >&2; exit 2; }
[[ -t 0 ]] || { echo 'Run this step in an interactive terminal.' >&2; exit 2; }
ulimit -c 0

RUN="$(python3 "$HERE/secret-endpoints.py" --show-run "$LEDGER" "$RUN_SELECTION" "$ACCOUNT" "$REGION")"
RUN_ID="$(jq -er '.runId' <<< "$RUN")"
DEPLOY_RECORD="$LEDGER/$RUN_ID/app-deploy.json"
HEALTH_RECORD="$LEDGER/$RUN_ID/app-health.json"
printf 'DR run: %s\nRestored primary: %s\nRestored replica: %s\n' \
  "$RUN_ID" "$(jq -er '.newHost' <<< "$RUN")" "$(jq -er '.newReplicaHost' <<< "$RUN")"

if [[ "$MODE" == connectivity ]]; then
  [[ -f "$DEPLOY_RECORD" ]] \
    || { echo 'Run P3-S03 and record deployment/convergence before attempting T8.' >&2; exit 2; }
  jq -e --arg run "$RUN_ID" '.runId==$run and .status=="owner-confirmed" and .servicesConverged==true' \
    "$DEPLOY_RECORD" >/dev/null \
    || { echo 'P3-S03 deployment/convergence attestation is required before T8.' >&2; exit 2; }
  OWNER="$(jq -er '.appOwner' "$DEPLOY_RECORD")"
  [[ ! -e "$HEALTH_RECORD" ]] || { echo 'T8 connectivity is already recorded for this run.' >&2; exit 2; }
  printf 'Deployment evidence: %s\n' "$(jq -er '.evidenceRef' "$DEPLOY_RECORD")"
  read -r -p "App owner [${OWNER}]: " OWNER_INPUT
  OWNER="${OWNER_INPUT:-$OWNER}"
  [[ "$OWNER" == "$(jq -er '.appOwner' "$DEPLOY_RECORD")" ]] \
    || { echo 'T8 must be confirmed by the app owner recorded for deployment.' >&2; exit 2; }
  read -r -p 'Did the running app pass its health check against the restored DB endpoint? [y/N]: ' CONNECTED
  [[ "$CONNECTED" =~ ^[Yy]$ ]] || { echo 'T8 not recorded; service RTO continues.' >&2; exit 2; }
  read -r -p 'Health-check evidence/logs reference: ' EVIDENCE_REF
  [[ -n "$EVIDENCE_REF" ]] || { echo 'A health-check evidence reference is required.' >&2; exit 2; }
  T0_AT="${BB3_T0_AT:-}"
  if [[ -z "$T0_AT" ]]; then
    read -r -p 'Impact start T0 (UTC ISO-8601): ' T0_AT
  fi
  [[ -n "$T0_AT" ]] || { echo 'T0 is required to calculate Service RTO.' >&2; exit 2; }
  RESULT="$(python3 "$HERE/secret-endpoints.py" --record-app-health \
    "$LEDGER" "$RUN_ID" "$ACCOUNT" "$REGION" "$OWNER" "$EVIDENCE_REF" "$T0_AT")"
  jq '{runId,appOwner,connectivityVerified,primaryHost,replicaHost,evidenceRef,t0At,t8At,serviceRtoMinutes}' <<< "$RESULT"
  echo 'T8 recorded. Service RTO is T8-T0; the separate business transaction/readback remains T9.'
  exit 0
fi

[[ -f "$HEALTH_RECORD" ]] \
  || { echo 'Run P4-S01 and record T8 app connectivity before attempting T9.' >&2; exit 2; }
jq -e --arg run "$RUN_ID" --arg account "$ACCOUNT" --arg region "$REGION" \
  '.runId==$run and .account==$account and .region==$region and .status=="owner-confirmed" and .connectivityVerified==true' \
  "$HEALTH_RECORD" >/dev/null \
  || { echo 'A matching T8 app-connectivity record is required before T9.' >&2; exit 2; }
[[ ! -e "$LEDGER/$RUN_ID/app-e2e.json" ]] \
  || { echo 'T9 business validation is already recorded for this run.' >&2; exit 2; }
OWNER="$(jq -er '.appOwner' "$HEALTH_RECORD")"
printf 'T8 recorded at: %s\n' "$(jq -er '.t8At' "$HEALTH_RECORD")"
printf 'App owner: %s\n' "$OWNER"
read -r -p 'Did the application complete a successful business transaction and readback on the restored DB path? [y/N]: ' PASSED
[[ "$PASSED" =~ ^[Yy]$ ]] || { echo 'T9 not recorded; business validation remains pending.' >&2; exit 2; }
read -r -p 'Business Transaction ID/reference ID (do not put business payload): ' TRANSACTION_REF
[[ -n "$TRANSACTION_REF" ]] || { echo 'A transaction/reference ID is required.' >&2; exit 2; }
RESULT="$(python3 "$HERE/secret-endpoints.py" --record-app-e2e \
  "$LEDGER" "$RUN_ID" "$ACCOUNT" "$REGION" "$OWNER" "$TRANSACTION_REF")"
jq '{runId,appOwner,transactionRef,transactionSucceeded,t0At,t8At,t9At,serviceRtoMinutes,businessValidationMinutes}' <<< "$RESULT"
echo 'T9 recorded. Business validation time T9-T8 is reported separately from Service RTO T8-T0.'