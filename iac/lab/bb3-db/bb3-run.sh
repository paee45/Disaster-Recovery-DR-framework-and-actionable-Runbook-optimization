#!/usr/bin/env bash
set -euo pipefail
set +x

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
CONFIG="$ROOT/iac/sandbox.env"
SCENARIO=''
CURRENT_STEP=''

list_steps() {
  cat <<'EOF'
BB3 S3 RDS drill steps:
  P1-S02  Discover/select source, snapshot, and restore targets
  P1-S03  Capture/checksum original primary and replica baseline
  P2-S00  Preview snapshot, tag, parameter, and restore-request comparisons (read-only)
  P2-S01  Restore primary (explicit tag, data-loss, parameter, and mutation gates)
  P2-S02  Wait for restored primary to become available
  P2-S03  Compare/harden restored primary
  P2-S04  Wait for primary after hardening
  P2-S05  Create read replica (explicit mutation gate)
  P2-S06  Wait for read replica to become available
  P2-S07  Compare/harden new replica
  P2-S08  Wait for replica after hardening
  P2-S09  Check both saved targets (read-only)
  P3-S02  Optional endpoint-only secret preview/update (explicit --only; not in all-RDS run)

Run all RDS steps in order: bb3-run.sh S3
Run selected steps only:  bb3-run.sh S3 --only P1-S02,P2-S00
Run from the repository root. Direct underlying scripts remain available for overrides.
EOF
}

usage() {
  cat >&2 <<'EOF'
Usage:
  bash iac/lab/bb3-db/bb3-run.sh --list
  bash iac/lab/bb3-db/bb3-run.sh S3 [--only P1-S02,P2-S00]
EOF
  list_steps >&2
  exit 2
}

on_interrupt() {
  case "$CURRENT_STEP" in
    P2-S02|P2-S04|P2-S06|P2-S08)
      printf '\nInterrupted while waiting at %s. Resume only this waiter; it will not repeat the mutation:\n' "$CURRENT_STEP" >&2
      printf 'bash iac/lab/bb3-db/bb3-run.sh %s --only %s\n' "${SCENARIO:-S3}" "$CURRENT_STEP" >&2
      ;;
    P2-S01)
      printf '\nInterrupted during restore submission. Do not rerun P2-S01 until you inspect whether AWS accepted it. Check saved targets:\n' >&2
      printf 'bash iac/lab/bb3-db/bb3-run.sh %s --only P2-S09\n' "${SCENARIO:-S3}" >&2
      printf 'If the primary exists, continue with: bash iac/lab/bb3-db/bb3-run.sh %s --only P2-S02\n' "${SCENARIO:-S3}" >&2
      ;;
    P2-S05)
      printf '\nInterrupted during replica creation. Do not rerun P2-S05 until you inspect whether AWS accepted it. Check saved targets:\n' >&2
      printf 'bash iac/lab/bb3-db/bb3-run.sh %s --only P2-S09\n' "${SCENARIO:-S3}" >&2
      printf 'If the replica exists, continue with: bash iac/lab/bb3-db/bb3-run.sh %s --only P2-S06\n' "${SCENARIO:-S3}" >&2
      ;;
    P2-S03|P2-S07)
      printf '\nInterrupted during a hardening step. Inspect both saved targets before resuming:\n' >&2
      printf 'bash iac/lab/bb3-db/bb3-run.sh %s --only P2-S09\n' "${SCENARIO:-S3}" >&2
      printf 'Then rerun the relevant validation step only after reviewing the current settings.\n' >&2
      ;;
    *)
      printf '\nInterrupted during %s. Resume this read-only/current step with:\n' "${CURRENT_STEP:-the current step}" >&2
      printf 'bash iac/lab/bb3-db/bb3-run.sh %s --only %s\n' "${SCENARIO:-S3}" "${CURRENT_STEP:-P1-S02}" >&2
      ;;
  esac
  exit 130
}
trap on_interrupt INT

if [[ $# == 1 && "$1" == --list ]]; then
  list_steps
  exit 0
fi
[[ $# -ge 1 && "$1" == S3 ]] || usage
SCENARIO="$1"; shift
ONLY=''
STEP_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) list_steps; exit 0 ;;
    --only)
      [[ $# -ge 2 && -z "$ONLY" ]] || usage
      ONLY="$2"; shift 2
      STEP_ARGS=("$@")
      break ;;
    *) usage ;;
  esac
done

ALL_STEPS=(P1-S02 P1-S03 P2-S00 P2-S01 P2-S02 P2-S03 P2-S04 P2-S05 P2-S06 P2-S07 P2-S08 P2-S09)
if [[ -n "$ONLY" ]]; then
  IFS=',' read -r -a STEPS <<< "$ONLY"
else
  STEPS=("${ALL_STEPS[@]}")
fi
if ((${#STEP_ARGS[@]} > 0 && ${#STEPS[@]} != 1)); then
  echo 'Step-specific arguments require exactly one --only step ID.' >&2
  usage
fi

load_environment() {
  [[ -f "$CONFIG" ]] || { echo 'Missing ignored iac/sandbox.env; run from the repository root.' >&2; return 2; }
  # shellcheck source=/dev/null
  source "$CONFIG"
  unset TF_VAR_terrakube_token AWS_DEFAULT_PROFILE
  PROFILE="${TF_VAR_aws_profile:-}"
  REGION="${TF_VAR_region:-}"
  ACCOUNT="${TF_VAR_account_id:-}"
  [[ "$PROFILE" =~ ^(lab_sandbox|pa_aws_sandbox|pa_iam_aws_sandbox)$ \
    && "$REGION" == ap-southeast-1 && "$ACCOUNT" =~ ^[0-9]{12}$ ]] \
    || { echo 'Sandbox profile, region or account is invalid.' >&2; return 2; }
  CALLER="$(aws --profile "$PROFILE" --region "$REGION" --no-cli-pager sts get-caller-identity --query Account --output text)"
  [[ "$CALLER" == "$ACCOUNT" ]] || { echo 'AWS caller does not match the configured sandbox account.' >&2; return 2; }
}

wait_for_target() {
  local target="$1" description="$2"
  load_environment
  printf '%s: waiting for %s to become available. Press Ctrl+C to stop; the resume command will be printed.\n' \
    "$CURRENT_STEP" "$target"
  aws --profile "$PROFILE" --region "$REGION" --no-cli-pager rds wait db-instance-available \
    --db-instance-identifier "$target"
  printf '%s: %s is available.\n' "$CURRENT_STEP" "$target"
}

run_step() {
  CURRENT_STEP="$1"
  shift
  printf '\n== %s ==\n' "$CURRENT_STEP"
  case "$CURRENT_STEP" in
    P1-S02)
      load_environment
      if [[ $# -gt 0 && "$1" =~ ^(dev|uat|prod)$ ]]; then
        ENV="$1"; shift
      fi
      [[ "${ENV:-}" =~ ^(dev|uat|prod)$ ]] || { echo 'Set ENV in iac/sandbox.env before discovery.' >&2; return 2; }
      bash "$HERE/discover-env.sh" "$ENV" "$@"
      ;;
    P1-S03)
      bash "$HERE/capture-baseline.sh" "$@"
      ;;
    P2-S00)
      bash "$HERE/restore-drill.sh" preview "$@"
      ;;
    P2-S01)
      bash "$HERE/restore-drill.sh" restore "$@"
      ;;
    P2-S02)
      load_environment
      wait_for_target "${BB3_RESTORE_TARGET_PRIMARY_ID:-}" 'restored primary'
      ;;
    P2-S03)
      bash "$HERE/restore-drill.sh" harden-primary "$@"
      ;;
    P2-S04)
      load_environment
      wait_for_target "${BB3_RESTORE_TARGET_PRIMARY_ID:-}" 'hardened primary'
      ;;
    P2-S05)
      bash "$HERE/restore-drill.sh" replica "$@"
      ;;
    P2-S06)
      load_environment
      wait_for_target "${BB3_RESTORE_TARGET_REPLICA_ID:-}" 'new replica'
      ;;
    P2-S07)
      bash "$HERE/restore-drill.sh" harden-replica "$@"
      ;;
    P2-S08)
      load_environment
      wait_for_target "${BB3_RESTORE_TARGET_REPLICA_ID:-}" 'hardened replica'
      ;;
    P2-S09)
      bash "$HERE/restore-drill.sh" status
      ;;
    P3-S02)
      bash "$HERE/secret-endpoints.sh" "$@"
      ;;
    *) echo "Unknown BB3 step ID: $CURRENT_STEP" >&2; list_steps >&2; return 2 ;;
  esac
}

for CURRENT_STEP in "${STEPS[@]}"; do
  [[ "$CURRENT_STEP" =~ ^P[123]-S[0-9]{2}$ ]] || { echo "Invalid BB3 step ID: $CURRENT_STEP" >&2; list_steps >&2; exit 2; }
  if [[ "$ONLY" != '' ]]; then
    run_step "$CURRENT_STEP" "${STEP_ARGS[@]}"
  else
    run_step "$CURRENT_STEP"
  fi
done
CURRENT_STEP=''