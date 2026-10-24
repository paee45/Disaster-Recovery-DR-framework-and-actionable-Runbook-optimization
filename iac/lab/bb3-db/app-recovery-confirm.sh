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
MODE=''
RUN_SELECTION=latest
FAILBACK=false
[[ $# -ge 1 ]] || { echo 'Usage: app-recovery-confirm.sh <connectivity|e2e> [--run-id DR-ID | --failback DR-ID]' >&2; exit 2; }
MODE="$1"; shift
[[ "$MODE" =~ ^(connectivity|e2e)$ ]] || { echo 'Mode must be connectivity or e2e.' >&2; exit 2; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id) [[ $# -ge 2 ]] || exit 2; RUN_SELECTION="$2"; shift 2 ;;
    --failback)
      [[ $# -ge 2 && "$2" =~ ^DR-[A-Za-z0-9_-]{1,120}$ && "$FAILBACK" == false ]] \
        || { echo 'Failback requires one explicit DR-ID.' >&2; exit 2; }
      FAILBACK=true; RUN_SELECTION="$2"; shift 2 ;;
    *) echo 'Usage: app-recovery-confirm.sh <connectivity|e2e> [--run-id DR-ID | --failback DR-ID]' >&2; exit 2 ;;
  esac
done
git -C "$ROOT" check-ignore -q "$LEDGER/check.json" \
  || { echo 'App recovery records must be Git-ignored.' >&2; exit 2; }
[[ -t 0 ]] || { echo 'Run this step in an interactive terminal.' >&2; exit 2; }
ulimit -c 0

show_failback_report() {
  local result report_path color='' reset=''
  result="$(python3 "$HERE/secret-endpoints.py" --failback-result-report \
    "$LEDGER" "$RUN_ID" "$ACCOUNT" "$REGION")"
  report_path="$(jq -er '.path' <<< "$result")"
  if [[ -t 1 && -z "${NO_COLOR+x}" && "${TERM:-dumb}" != dumb ]]; then
    color=$'\033[1;32m'
    reset=$'\033[0m'
  fi
  printf '\n%s============================================================\n' "$color"
  printf 'FAILBACK RESULT REPORT\n============================================================%s\n' "$reset"
  printf 'Evidence: %s (SHA-256: %s)\n\n' "$report_path" "$(jq -er '.reportSha256' <<< "$result")"
  cat "$report_path"
}

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
fi
DEPLOY_RECORD="$LEDGER/$RUN_ID/app-deploy.json"
HEALTH_RECORD="$LEDGER/$RUN_ID/app-health.json"
FAILBACK_DEPLOY_RECORD="$LEDGER/$RUN_ID/failback-app-deploy.json"
FAILBACK_HEALTH_RECORD="$LEDGER/$RUN_ID/failback-app-health.json"
FAILBACK_E2E_RECORD="$LEDGER/$RUN_ID/failback-app-e2e.json"
if [[ "$FAILBACK" == true ]]; then
  PRIMARY_HOST="$(jq -er '.primaryHost' <<< "$RUN")"
  REPLICA_HOST="$(jq -er '.replicaHost' <<< "$RUN")"
  printf 'DR run: %s\nOriginal primary: %s\nOriginal replica: %s\n' \
    "$RUN_ID" "$PRIMARY_HOST" "$REPLICA_HOST"
  if [[ "$MODE" == connectivity ]]; then
    [[ -f "$FAILBACK_DEPLOY_RECORD" ]] \
      || { echo 'Run P3-S03 --failback DR-ID and confirm manual deployment/convergence first.' >&2; exit 2; }
    OWNER="$(jq -er '.appOwner' "$FAILBACK_DEPLOY_RECORD")"
    [[ ! -e "$FAILBACK_HEALTH_RECORD" ]] \
      || { echo 'Failback app health is already recorded for this run.' >&2; exit 2; }
    printf 'Reusing saved app owner: %s\n' "$OWNER"
    [[ "$OWNER" == "$(jq -er '.failbackFence.appOwner' <<< "$RUN")" ]] \
      || { echo 'Failback health must be confirmed by the deployment app owner.' >&2; exit 2; }
    bb3_prompt_read CONNECTED 'Did the app health check succeed on the original primary/replica endpoints? [y/N]: '
    [[ "$CONNECTED" =~ ^[Yy]$ ]] || { echo 'Failback health not recorded.' >&2; exit 2; }
    bb3_prompt_read EVIDENCE_REF 'Health-check evidence reference: '
    [[ -n "$EVIDENCE_REF" ]] || { echo 'Health-check evidence reference is required.' >&2; exit 2; }
    SAMPLE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    bb3_prompt_read HEALTH_AT "Actual successful health-check time UTC [${SAMPLE}]: "
    HEALTH_AT="${HEALTH_AT:-$SAMPLE}"
    RESULT="$(python3 "$HERE/secret-endpoints.py" --record-failback-app-health \
      "$LEDGER" "$RUN_ID" "$ACCOUNT" "$REGION" "$OWNER" "$EVIDENCE_REF" "$HEALTH_AT")"
    jq '{runId,operation,appOwner,healthVerified,primaryHost,replicaHost,evidenceRef,healthCheckAt}' <<< "$RESULT"
    echo 'Failback health recorded as supplemental local evidence; recovery T8/T9 are unchanged.'
    exit 0
  fi
  [[ -f "$FAILBACK_HEALTH_RECORD" ]] \
    || { echo 'Run P4-S01 --failback DR-ID and confirm original-pair health first.' >&2; exit 2; }
  OWNER="$(jq -er '.appOwner' "$FAILBACK_HEALTH_RECORD")"
  printf 'Reusing saved app owner: %s\n' "$OWNER"
  if [[ ! -e "$FAILBACK_E2E_RECORD" ]]; then
  [[ "$OWNER" == "$(jq -er '.failbackFence.appOwner' <<< "$RUN")" ]] \
    || { echo 'Failback transaction must be confirmed by the deployment app owner.' >&2; exit 2; }
  bb3_prompt_read PASSED 'Did a successful business transaction and readback complete on the original DB path? [y/N]: '
  [[ "$PASSED" =~ ^[Yy]$ ]] || { echo 'Failback business validation not recorded.' >&2; exit 2; }
  bb3_prompt_read TRANSACTION_REF 'Non-secret transaction/reference ID (no business payload): '
  [[ -n "$TRANSACTION_REF" ]] || { echo 'A non-secret transaction reference is required.' >&2; exit 2; }
  SAMPLE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  bb3_prompt_read TRANSACTION_AT "Actual successful transaction time UTC [${SAMPLE}]: "
  TRANSACTION_AT="${TRANSACTION_AT:-$SAMPLE}"
  RESULT="$(python3 "$HERE/secret-endpoints.py" --record-failback-app-e2e \
    "$LEDGER" "$RUN_ID" "$ACCOUNT" "$REGION" "$OWNER" "$TRANSACTION_REF" "$TRANSACTION_AT")"
  jq '{runId,operation,appOwner,transactionRef,businessTransactionVerified,primaryHost,replicaHost,transactionAt}' <<< "$RESULT"
  echo 'Failback business validation recorded as supplemental local evidence; recovery T8/T9 are unchanged.'
  else
    echo 'Reusing saved failback transaction; the original journal will not be changed.'
  fi
  REVIEW="$(python3 "$HERE/secret-endpoints.py" --review-failback-signoff \
    "$LEDGER" "$RUN_ID" "$ACCOUNT" "$REGION")"
  jq '{runId,appOwner,primaryHost,replicaHost,
    deploymentEvidence:.evidence.deployment.evidenceRef,
    healthEvidence:.evidence.health.evidenceRef,
    healthAt:.evidence.health.healthCheckAt,
    transactionRef:.evidence.transaction.transactionRef,
    transactionAt:.evidence.transaction.transactionAt}' <<< "$REVIEW"
  if [[ -e "$LEDGER/$RUN_ID/failback-signoff.json" ]]; then
    echo 'Failback sign-off already exists; no record was overwritten.'
    show_failback_report
    exit 0
  fi
  echo 'Review actual supporting evidence, not placeholder/prompt-test inputs. References are not independently verified.'
  SIGNOFF_OWNER="$(jq -er '.appOwner' <<< "$REVIEW")"
  DEPLOYMENT_REF="$(jq -er '.evidence.deployment.evidenceRef' <<< "$REVIEW")"
  HEALTH_REF="$(jq -er '.evidence.health.evidenceRef' <<< "$REVIEW")"
  BUSINESS_REF="$(jq -er '.evidence.transaction.transactionRef' <<< "$REVIEW")"
  echo 'Reusing the displayed saved deployment, health and transaction references for sign-off; no re-entry required.'
  bb3_prompt_token_read SIGNOFF_APPROVAL 'Type ' SIGN-OFF-FAILBACK \
    ' to confirm evidence review and approve failback (Enter leaves pending; not resource deletion): '
  if [[ -z "$SIGNOFF_APPROVAL" ]]; then
    echo 'Transaction retained; failback sign-off remains pending. No cleanup authorized.'
    exit 0
  fi
  RESULT="$(python3 "$HERE/secret-endpoints.py" --record-failback-signoff \
    "$LEDGER" "$RUN_ID" "$ACCOUNT" "$REGION" "$SIGNOFF_OWNER" \
    "$DEPLOYMENT_REF" "$HEALTH_REF" "$BUSINESS_REF" "$SIGNOFF_APPROVAL")"
  jq '{runId,appOwner,status,signedOffAt,cleanupAuthorized}' <<< "$RESULT"
  show_failback_report
  printf 'Next: review retirement of only this run\047s restored DB pair and quarantine SG.\n'
  bb3_prompt_read CLEANUP_READY 'Open the separately approved retirement workflow now? [y/N]: '
  if [[ "$CLEANUP_READY" =~ ^[Yy]$ ]]; then
    [[ -f "$HERE/retire-restored.sh" ]] \
      || { echo 'Retirement workflow is not implemented yet; no resources were changed.' >&2; exit 2; }
    bash "$HERE/retire-restored.sh" --failback "$RUN_ID"
  fi
  exit 0
fi
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
  printf 'Reusing saved app owner: %s\n' "$OWNER"
  bb3_prompt_read CONNECTED 'Did the running app pass its health check against the restored DB endpoint? [y/N]: '
  [[ "$CONNECTED" =~ ^[Yy]$ ]] || { echo 'T8 not recorded; service RTO continues.' >&2; exit 2; }
  bb3_prompt_read EVIDENCE_REF 'Health-check evidence/logs reference: '
  [[ -n "$EVIDENCE_REF" ]] || { echo 'A health-check evidence reference is required.' >&2; exit 2; }
  T0_AT="${BB3_T0_AT:-}"
  if [[ -z "$T0_AT" ]]; then
    bb3_prompt_read T0_AT 'Impact start T0 (UTC ISO-8601): '
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
bb3_prompt_read PASSED 'Did the application complete a successful business transaction and readback on the restored DB path? [y/N]: '
[[ "$PASSED" =~ ^[Yy]$ ]] || { echo 'T9 not recorded; business validation remains pending.' >&2; exit 2; }
bb3_prompt_read TRANSACTION_REF 'Business Transaction ID/reference ID (do not put business payload): '
[[ -n "$TRANSACTION_REF" ]] || { echo 'A transaction/reference ID is required.' >&2; exit 2; }
RESULT="$(python3 "$HERE/secret-endpoints.py" --record-app-e2e \
  "$LEDGER" "$RUN_ID" "$ACCOUNT" "$REGION" "$OWNER" "$TRANSACTION_REF")"
jq '{runId,appOwner,transactionRef,transactionSucceeded,t0At,t8At,t9At,serviceRtoMinutes,businessValidationMinutes}' <<< "$RESULT"
echo 'T9 recorded. Business validation time T9-T8 is reported separately from Service RTO T8-T0.'