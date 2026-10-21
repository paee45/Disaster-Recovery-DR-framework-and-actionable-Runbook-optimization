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
read -r -p 'Approved deployed commit SHA (40 hex characters): ' COMMIT
read -r -p 'Deployment/convergence evidence reference: ' EVIDENCE_REF
[[ -n "$APP_OWNER" && "$COMMIT" =~ ^[0-9a-fA-F]{40}$ && -n "$EVIDENCE_REF" ]] \
  || { echo 'Owner, full commit SHA, and evidence reference are required.' >&2; exit 2; }
read -r -p 'Owner confirms both restored endpoints and all expected services/tasks converged? Type DEPLOYED-AND-CONVERGED: ' CONFIRM
[[ "$CONFIRM" == DEPLOYED-AND-CONVERGED ]] || { echo 'Deployment confirmation not recorded.' >&2; exit 2; }
RESULT="$(python3 "$HERE/secret-endpoints.py" --record-app-deploy "$LEDGER" "$RUN_ID" "$ACCOUNT" "$REGION" "$APP_OWNER" "$COMMIT" "$EVIDENCE_REF")"
jq '{runId,mode,status,appOwner,deployedCommit,evidenceRef,servicesConverged,primaryHost,replicaHost,recordedAt}' <<< "$RESULT"
echo 'Deployment attestation recorded. Run P4-S01 after the app DB health check to record T8, then P4-S02 after the business transaction/readback to record T9.'
