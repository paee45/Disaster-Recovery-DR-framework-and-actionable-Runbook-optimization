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
  P0-S01  Discover/select source, snapshot, and restore targets
  P0-S02  Capture/checksum original primary and replica baseline
  P0-S03  Quarantine source DB pair and capture app failure evidence
  P1-S01-1  Record evidence-based impact T0 (Enter defaults to current UTC)
  P1-S01-2  Record declaration T1 and select S3 (reuse the P0 run ID)
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
  P3-S01  Verify P0 no-ingress SG and confirm existing sessions closed; no source mutation
  P3-S02  Secret update: automatic CLI or verify manual update (explicit selection)
  P3-S03  App deploy: automatic unavailable; confirm manual deployment (explicit selection)
  P4-S01  Confirm app health check connects to restored DB; record T8 and stop Service RTO
  P4-S02  Confirm business transaction/readback; record T9 separately

Manual app-owner gate (not a runner command): P4-G4 declare services restored and record T10.

Run all RDS steps in order: bb3-run.sh S3
Run selected steps only:  bb3-run.sh S3 --only P0-S01,P0-S02,P0-S03
Run an inclusive range:   bb3-run.sh S3 --from P2-S06 --to P2-S09
Inspect a range only:     bb3-run.sh S3 --from P3-S01 --to P4-S02 --list
Run from the repository root. Direct underlying scripts remain available for overrides.
EOF
}

usage() {
  cat >&2 <<'EOF'
Usage:
  bash iac/lab/bb3-db/bb3-run.sh --list
  bash iac/lab/bb3-db/bb3-run.sh S3 [--only P0-S01,P0-S02 [step arguments]]
  bash iac/lab/bb3-db/bb3-run.sh S3 [--from STEP] [--to STEP] [--list]
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
FROM=''
TO=''
LIST_ONLY=false
STEP_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) LIST_ONLY=true; shift ;;
    --from)
      [[ $# -ge 2 && -n "$2" && -z "$FROM" && -z "$ONLY" ]] || usage
      FROM="$2"; shift 2 ;;
    --to)
      [[ $# -ge 2 && -n "$2" && -z "$TO" && -z "$ONLY" ]] || usage
      TO="$2"; shift 2 ;;
    --only)
      [[ $# -ge 2 && -n "$2" && -z "$ONLY$FROM$TO" ]] || usage
      ONLY="$2"; shift 2
      STEP_ARGS=("$@")
      for argument in "${STEP_ARGS[@]}"; do
        [[ "$argument" != --from && "$argument" != --to && "$argument" != --only ]] || usage
      done
      break ;;
    *) usage ;;
  esac
done

ALL_STEPS=(P0-S01 P0-S02 P0-S03 P1-S01-1 P1-S01-2 P2-S00 P2-S01 P2-S02 P2-S03 P2-S04 P2-S05 P2-S06 P2-S07 P2-S08 P2-S09 P3-S01 P3-S02 P3-S03 P4-S01 P4-S02)
step_index() {
  local step="$1" index
  for index in "${!ALL_STEPS[@]}"; do
    if [[ "${ALL_STEPS[$index]}" == "$step" ]]; then
      printf '%s\n' "$index"
      return 0
    fi
  done
  printf 'Unknown BB3 step ID: %s. Use --list for executable steps.\n' "$step" >&2
  return 2
}
if [[ -n "$ONLY" ]]; then
  [[ "$ONLY" != ,* && "$ONLY" != *, && "$ONLY" != *,,* ]] || usage
  IFS=',' read -r -a STEPS <<< "$ONLY"
elif [[ -n "$FROM$TO" ]]; then
  first_index="$(step_index "${FROM:-P0-S01}")" || exit 2
  last_index="$(step_index "${TO:-P4-S02}")" || exit 2
  ((first_index <= last_index)) || { echo '--from must not follow --to.' >&2; exit 2; }
  STEPS=("${ALL_STEPS[@]:first_index:last_index-first_index+1}")
else
  last_index="$(step_index P2-S09)"
  STEPS=("${ALL_STEPS[@]:0:last_index+1}")
fi
for selected_step in "${STEPS[@]}"; do
  step_index "$selected_step" >/dev/null || exit 2
done
if [[ "$LIST_ONLY" == true ]]; then
  if [[ -n "$FROM$TO$ONLY" ]]; then
    printf 'Selected BB3 steps (no actions run):\n'
    printf '  %s\n' "${STEPS[@]}"
  else
    list_steps
  fi
  exit 0
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
  printf '%s: waiting for %s (%s) to become available. Press Ctrl+C to stop; the resume command will be printed.\n' \
    "$CURRENT_STEP" "$target" "$description"
  aws --profile "$PROFILE" --region "$REGION" --no-cli-pager rds wait db-instance-available \
    --db-instance-identifier "$target"
  printf '%s: %s is available.\n' "$CURRENT_STEP" "$target"
}

step_preview() {
  local action expected what_label='  What:' expected_label='  Expected:'
  case "$1" in
    P0-S01) action='Discover and save the source pair, snapshot, and restore targets.'; expected='A reviewed source/replica selection and deterministic restore target IDs are saved.' ;;
    P0-S02) action='Capture the original primary/replica API baseline and checksums.'; expected='A complete, checksum-verified baseline matching the selected DBs is recorded before the quarantine.' ;;
    P0-S03) action='Attach the run-scoped no-ingress SG to the source pair.'; expected='Both attachments are active; app failure evidence is recorded; the original SG sets remain in the baseline.' ;;
    P1-S01-1) action='Record the service-impact time T0 from app/monitor evidence; Enter defaults to current UTC.'; expected='UTC T0 and its required evidence reference are saved for the existing P0 run ID.' ;;
    P1-S01-2) action='Record declaration T1 and select the recovery scenario.'; expected='T1 is not earlier than T0; T1 evidence is required if backfilled; the existing S3 run ID is declared.' ;;
    P2-S00) action='Preview snapshot metadata, baseline differences, parameters, and restore requests.'; expected='Read-only comparison is reviewed; no RDS resource is created or changed.' ;;
    P2-S01) action='Restore a new primary from the selected snapshot.'; expected='A new target is submitted only after explicit mutation approval; the restore API omits PreferredMaintenanceWindow, which P2-S03 applies after creation.' ;;
    P2-S02) action='Wait for the restored primary.'; expected='RDS reports the saved primary target as available.' ;;
    P2-S03) action='Harden and validate the restored primary against the captured baseline.'; expected='Required RDS settings and parameter values match the reviewed baseline.' ;;
    P2-S04) action='Wait for the hardened primary.'; expected='RDS reports the primary as available after hardening.' ;;
    P2-S05) action='Create the restored read replica.'; expected='The replica API omits PreferredMaintenanceWindow; P2-S07 verifies/applies it after the replica is available.' ;;
    P2-S06) action='Wait for the restored replica.'; expected='RDS reports the saved replica target as available.' ;;
    P2-S07) action='Harden and validate the restored replica.'; expected='Replica topology and captured parameter/settings checks pass.' ;;
    P2-S08) action='Wait for the hardened replica.'; expected='RDS reports the replica as available after hardening.' ;;
    P2-S09) action='Inspect both saved restore targets.'; expected='Current status and topology are shown; no AWS resource is changed.' ;;
    P3-S01) action='Verify the P0 run-scoped no-ingress SG and confirm existing sessions are closed.'; expected='Both source DBs must still have only the verified quarantine SG; no SG change or source stop is submitted here.' ;;
    P3-S02) action='Update or verify the app secret endpoint pair.'; expected='Both endpoints match the selected restored pair; any write requires the matching verified fence.' ;;
    P3-S03) action='Record the application owner deployment and service convergence attestation.'; expected='No deployment runs here; owner confirmation and one sanitized multiline deployment log are captured.' ;;
    P4-S01) action='Confirm the running app health check reaches the restored DB path.'; expected='After P3-S03, owner evidence and UTC T0 produce T8 and Service RTO T8-T0.' ;;
    P4-S02) action='Confirm the separate business transaction and readback.'; expected='After T8, the owner records the transaction reference and T9; validation duration is T9-T8.' ;;
    *) action='Run the selected BB3 step.'; expected='Follow the step output and approval prompts.' ;;
  esac
  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    printf '\033[1;36m%s\033[0m %s\n\033[1;36m%s\033[0m %s\n' \
      "$what_label" "$action" "$expected_label" "$expected"
  else
    printf '%s %s\n%s %s\n' "$what_label" "$action" "$expected_label" "$expected"
  fi
}

run_step() {
  CURRENT_STEP="$1"
  shift
  printf '\n== %s ==\n' "$CURRENT_STEP"
  step_preview "$CURRENT_STEP"
  case "$CURRENT_STEP" in
    P1-S01-1)
      bash "$HERE/incident-start.sh" impact "$@"
      ;;
    P1-S01-2)
      bash "$HERE/incident-start.sh" declare "$@"
      ;;
    P0-S01)
      load_environment
      if [[ $# -gt 0 && "$1" =~ ^(dev|uat|prod)$ ]]; then
        ENV="$1"; shift
      fi
      [[ "${ENV:-}" =~ ^(dev|uat|prod)$ ]] || { echo 'Set ENV in iac/sandbox.env before discovery.' >&2; return 2; }
      bash "$HERE/discover-env.sh" "$ENV" "$@"
      ;;
    P0-S02)
      bash "$HERE/capture-baseline.sh" "$@"
      ;;
    P0-S03)
      bash "$HERE/fence-request.sh" pre-impact "$@"
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
    P3-S01)
      bash "$HERE/fence-confirm.sh" "$@"
      ;;
    P3-S02)
      bash "$HERE/secret-endpoints.sh" "$@"
      ;;
    P3-S03)
      bash "$HERE/app-deploy-confirm.sh" "$@"
      ;;
    P4-S01)
      bash "$HERE/app-recovery-confirm.sh" connectivity "$@"
      ;;
    P4-S02)
      bash "$HERE/app-recovery-confirm.sh" e2e "$@"
      ;;
    *) echo "Unknown BB3 step ID: $CURRENT_STEP" >&2; list_steps >&2; return 2 ;;
  esac
}

for CURRENT_STEP in "${STEPS[@]}"; do
  [[ "$CURRENT_STEP" =~ ^P[0-4]-S[0-9]{2}(-[12])?$ ]] || { echo "Invalid BB3 step ID: $CURRENT_STEP" >&2; list_steps >&2; exit 2; }
  if [[ "$ONLY" != '' ]]; then
    run_step "$CURRENT_STEP" "${STEP_ARGS[@]}"
  else
    run_step "$CURRENT_STEP"
  fi
done
CURRENT_STEP=''