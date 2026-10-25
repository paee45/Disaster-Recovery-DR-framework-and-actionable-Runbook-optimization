#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
CONFIG="${BB3_SANDBOX_CONFIG:-$ROOT/iac/sandbox.env}"
MODE="${1:-}"
[[ $# -ge 1 && "$MODE" =~ ^(declare|package)$ ]] \
  || { echo 'Usage: closeout.sh declare|package [--run-id DR-ID]' >&2; exit 2; }
shift
SELECTION=''
if [[ $# -gt 0 ]]; then
  [[ $# == 2 && "$1" == --run-id ]] \
    || { echo 'Usage: closeout.sh declare|package [--run-id DR-ID]' >&2; exit 2; }
  SELECTION="$2"
fi
if [[ "$MODE" == declare ]]; then
  [[ -t 0 && -t 1 ]] || { echo 'Declaration requires an interactive terminal.' >&2; exit 2; }
fi
[[ -z "${AWS_ACCESS_KEY_ID:-}${AWS_SECRET_ACCESS_KEY:-}${AWS_SESSION_TOKEN:-}${AWS_SECURITY_TOKEN:-}" ]] \
  || { echo 'Unset exported AWS credentials.' >&2; exit 2; }
[[ -f "$CONFIG" && ! -L "$CONFIG" ]] || { echo 'Missing regular ignored sandbox config.' >&2; exit 2; }
git -C "$ROOT" check-ignore -q "$CONFIG" \
  || { echo 'Sandbox config must be Git-ignored.' >&2; exit 2; }
# shellcheck source=/dev/null
source "$CONFIG"
set +x
umask 077
export BB3_RTO_TARGET_MIN="${BB3_RTO_TARGET_MIN:-60}"
unset AWS_DEFAULT_PROFILE TF_VAR_terrakube_token
PROFILE="${TF_VAR_aws_profile:-}"
REGION="${TF_VAR_region:-}"
ACCOUNT="${TF_VAR_account_id:-}"
LEDGER="${BB3_LEDGER_DIR:-$ROOT/evidence/bb3-secret-endpoints}"
[[ "$PROFILE" =~ ^(lab_sandbox|pa_aws_sandbox|pa_iam_aws_sandbox)$ \
  && "$REGION" == ap-southeast-1 && "$ACCOUNT" =~ ^[0-9]{12}$ \
  && "${ENV:-}" =~ ^(dev|uat)$ ]] || { echo 'Only dev/uat sandbox is allowed.' >&2; exit 2; }
[[ -z "${AWS_ACCESS_KEY_ID:-}${AWS_SECRET_ACCESS_KEY:-}${AWS_SESSION_TOKEN:-}${AWS_SECURITY_TOKEN:-}" ]] \
  || { echo 'Unset exported AWS credentials.' >&2; exit 2; }
RUN_ID="${SELECTION:-${BB3_DR_ID:-}}"
[[ "$RUN_ID" =~ ^DR-[A-Za-z0-9_-]{1,120}$ ]] \
  || { echo 'Supply --run-id DR-ID or save BB3_DR_ID; latest is never selected.' >&2; exit 2; }
git -C "$ROOT" check-ignore -q "$LEDGER/$RUN_ID/closeout.json" \
  || { echo 'Closeout ledger must be Git-ignored.' >&2; exit 2; }
ulimit -c 0
exec python3 "$HERE/closeout.py" "$MODE" --root "$ROOT" --ledger "$LEDGER" \
  --run-id "$RUN_ID" --account "$ACCOUNT" --region "$REGION" --environment "$ENV"