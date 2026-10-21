#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
CONFIG="${BB3_SANDBOX_CONFIG:-$ROOT/iac/sandbox.env}"
LEDGER="${BB3_LEDGER_DIR:-$ROOT/evidence/bb3-secret-endpoints}"
MODE="${1:-}"
[[ $# == 1 && "$MODE" =~ ^(impact|declare)$ ]] \
  || { echo 'Usage: incident-start.sh <impact|declare>' >&2; exit 2; }
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
[[ -t 0 ]] || { echo 'Incident start requires an interactive terminal.' >&2; exit 2; }
git -C "$ROOT" check-ignore -q "$CONFIG" \
  || { echo 'sandbox.env must be Git-ignored.' >&2; exit 2; }

parse_utc() {
  python3 - "$1" <<'PY'
from datetime import datetime, timezone
import sys

try:
    value = datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
except (IndexError, ValueError):
    raise SystemExit(1)
if value.tzinfo is None or value.utcoffset() != timezone.utc.utcoffset(value):
    raise SystemExit(1)
print(value.isoformat())
PY
}

save_config() {
  local temporary="$1"
  shift
    awk '$0 !~ /^export BB3_T0_AT=/ && $0 !~ /^export BB3_T0_EVIDENCE_REF=/ &&
      $0 !~ /^export BB3_T1_AT=/ && $0 !~ /^export BB3_T1_EVIDENCE_REF=/ &&
      $0 !~ /^export BB3_SCENARIO=/ && $0 !~ /^export BB3_DR_ID=/' "$CONFIG" > "$temporary"
  printf 'export BB3_T0_AT=%q\nexport BB3_T0_EVIDENCE_REF=%q\n' "$T0_AT" "$T0_EVIDENCE_REF" >> "$temporary"
  if [[ -n "${BB3_T1_AT:-}" ]]; then printf 'export BB3_T1_AT=%q\n' "$BB3_T1_AT" >> "$temporary"; fi
    if [[ -n "${BB3_T1_EVIDENCE_REF:-}" ]]; then printf 'export BB3_T1_EVIDENCE_REF=%q\n' "$BB3_T1_EVIDENCE_REF" >> "$temporary"; fi
    if [[ -n "${BB3_SCENARIO:-}" ]]; then printf 'export BB3_SCENARIO=%q\n' "$BB3_SCENARIO" >> "$temporary"; fi
  if [[ -n "${BB3_DR_ID:-}" ]]; then printf 'export BB3_DR_ID=%q\n' "$BB3_DR_ID" >> "$temporary"; fi
  chmod 600 "$temporary"
  mv "$temporary" "$CONFIG"
}

if [[ "$MODE" == impact ]]; then
  [[ "${BB3_DR_ID:-}" =~ ^DR-[A-Za-z0-9_-]{1,120}$ && -f "$LEDGER/${BB3_DR_ID}/network-fence.json" ]] \
    || { echo 'Run P0-S03 to attach the quarantine SG before recording impact.' >&2; exit 2; }
  jq -e --arg run "$BB3_DR_ID" --arg account "$ACCOUNT" --arg region "$REGION" \
    --arg primary "${BB3_SOURCE_PRIMARY_ID:-}" --arg replica "${BB3_SOURCE_REPLICA_ID:-}" \
    '.runId==$run and .account==$account and .region==$region and .activePrimary==$primary and
     (.activeReplica // "")==$replica and .status=="attached"' \
    "$LEDGER/${BB3_DR_ID}/network-fence.json" >/dev/null \
    || { echo 'P0-S03 quarantine attachment is not verified for this source pair.' >&2; exit 2; }
  sample="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    printf '\033[1;32mCurrent UTC default: %s\033[0m\n' "$sample"
  else
    printf 'Current UTC default: %s\n' "$sample"
  fi
  read -r -p "Impact start T0 from app/monitor evidence (UTC ISO-8601) [${sample}]: " T0_INPUT
  T0_INPUT="${T0_INPUT:-$sample}"
  T0_AT="$(parse_utc "$T0_INPUT")" \
    || { echo 'T0 must be ISO-8601 UTC, for example 2026-10-21T00:15:00Z.' >&2; exit 2; }
  [[ ! -e "$LEDGER/${BB3_DR_ID}/incident.json" ]] \
    || { echo 'A DR run is already declared; use its saved T0 instead.' >&2; exit 2; }
  read -r -p "T0 incident/monitor evidence reference [${BB3_T0_EVIDENCE_REF:-}]: " T0_REF_INPUT
  T0_EVIDENCE_REF="${T0_REF_INPUT:-${BB3_T0_EVIDENCE_REF:-}}"
  [[ -n "$T0_EVIDENCE_REF" ]] || { echo 'T0 evidence reference is required.' >&2; exit 2; }
  temporary="$(mktemp "${CONFIG}.tmp.XXXXXX")"
  trap 'rm -f "$temporary"' EXIT
  save_config "$temporary"
  trap - EXIT
  printf 'Impact time saved: T0=%s (UTC), evidence=%s. T1 is not declared yet.\n' "$T0_AT" "$T0_EVIDENCE_REF"
  exit 0
fi

T0_AT="${BB3_T0_AT:-}"
T0_EVIDENCE_REF="${BB3_T0_EVIDENCE_REF:-}"
[[ -n "$T0_AT" && -n "$T0_EVIDENCE_REF" ]] \
  || { echo 'Run P1-S01-1 to record evidence-based T0 before declaring the incident.' >&2; exit 2; }
[[ "${BB3_DR_ID:-}" =~ ^DR-[A-Za-z0-9_-]{1,120}$ && -f "$LEDGER/${BB3_DR_ID}/network-fence.json" ]] \
  || { echo 'Run P0-S03 before declaring the incident.' >&2; exit 2; }
[[ -f "$LEDGER/check.json" ]] || git -C "$ROOT" check-ignore -q "$LEDGER/check.json" \
  || { echo 'Incident records must be Git-ignored.' >&2; exit 2; }
read -r -p 'Scenario to recover [S3 snapshot restore; S4/PITR is backlog] (S3): ' SCENARIO_INPUT
SCENARIO_INPUT="${SCENARIO_INPUT:-S3}"
[[ "$SCENARIO_INPUT" == S3 ]] || { echo 'Only S3 is implemented for BB3; S4/PITR remains backlog.' >&2; exit 2; }
sample="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
read -r -p "Incident declaration T1 UTC ISO-8601 [${sample}]: " T1_INPUT
T1_AT="$(parse_utc "${T1_INPUT:-$sample}")" \
  || { echo 'T1 must be ISO-8601 UTC, for example 2026-10-21T00:15:00Z.' >&2; exit 2; }
python3 - "$T0_AT" "$T1_AT" <<'PY'
from datetime import datetime
import sys
t0, t1 = (datetime.fromisoformat(value.replace("Z", "+00:00")) for value in sys.argv[1:])
if t0 > t1:
    raise SystemExit("T1 cannot be earlier than T0.")
PY
T1_EVIDENCE_REF="${BB3_T1_EVIDENCE_REF:-}"
if [[ -n "$T1_INPUT" ]]; then
  read -r -p 'T1 log/incident-declaration evidence reference: ' T1_EVIDENCE_REF
  [[ -n "$T1_EVIDENCE_REF" ]] || { echo 'Backdated or edited T1 requires an evidence reference.' >&2; exit 2; }
fi
[[ "$ENV" == uat ]] || { echo 'This BB3 runner is currently scoped to the UAT S3 scenario.' >&2; exit 2; }
DR_ID="$BB3_DR_ID"
RUN_DIR="$LEDGER/$DR_ID"
[[ -d "$RUN_DIR" && -f "$RUN_DIR/network-fence.json" ]] \
  || { echo 'P0 quarantine record is missing for this run ID.' >&2; exit 2; }
[[ ! -e "$RUN_DIR/incident.json" ]] || { echo 'Incident is already declared; resume the saved run.' >&2; exit 2; }
mkdir -p "$RUN_DIR"
chmod 700 "$LEDGER" "$RUN_DIR"
jq -n --arg run "$DR_ID" --arg env "$ENV" --arg scenario "$SCENARIO_INPUT" \
  --arg account "$ACCOUNT" --arg region "$REGION" --arg t0 "$T0_AT" \
  --arg t0ref "$T0_EVIDENCE_REF" --arg t1 "$T1_AT" --arg t1ref "$T1_EVIDENCE_REF" \
  --arg t1method "$(if [[ -n "$T1_INPUT" ]]; then printf evidence-backfill; else printf declaration-time; fi)" \
  '{runId:$run,scenario:$scenario,environment:$env,account:$account,region:$region,
    t0At:$t0,t0EvidenceRef:$t0ref,t1At:$t1,t1Method:$t1method,
    t1EvidenceRef:(if $t1ref=="" then null else $t1ref end),status:"declared"}' \
  > "$RUN_DIR/incident.json"
chmod 600 "$RUN_DIR/incident.json"
temporary="$(mktemp "${CONFIG}.tmp.XXXXXX")"
trap 'rm -f "$temporary"' EXIT
BB3_DR_ID="$DR_ID" BB3_T1_AT="$T1_AT" BB3_T1_EVIDENCE_REF="$T1_EVIDENCE_REF" \
  BB3_SCENARIO="$SCENARIO_INPUT" save_config "$temporary"
trap - EXIT
printf 'Declared S3 incident %s: T0=%s (evidence=%s), T1=%s UTC. No AWS resource was changed.\n' \
  "$DR_ID" "$T0_AT" "$T0_EVIDENCE_REF" "$T1_AT"