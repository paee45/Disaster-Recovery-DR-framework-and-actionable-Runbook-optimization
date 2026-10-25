#!/usr/bin/env bash
set -euo pipefail
set +x

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bb3-prompt.sh
source "$HERE/bb3-prompt.sh"
ROOT="$(cd "$HERE/../../.." && pwd)"
CONFIG="$ROOT/iac/sandbox.env"
SCENARIO=''
CURRENT_STEP=''
FAILBACK_RUN=''
CURRENT_ARGS=()
NEW_RUN=false
PROGRESS_ENABLED=false
PROGRESS_MODE=recovery
CURRENT_ACTION=''
NEXT_ACTION=preview
LEDGER="$ROOT/evidence/bb3-secret-endpoints"

list_steps() {
  cat <<'EOF'
BB3 S3 RDS drill steps:
  P0-S01  Discover/select source, snapshot, and restore targets
  P0-S02  Capture/checksum original primary and replica baseline
  P0-S03  Simulate app failure by cutting off new DB traffic with a no-ingress SG
  P1-S01-1  Record evidence-based impact T0 (Enter defaults to current UTC)
  P1-S01-2  Record declaration T1 for S3 without reselection (reuse the P0 run ID)
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
  P3-S03  App deploy: guarded automatic/guided SSH to dev/uat or manual completion confirmation
  P4-S01  Confirm restored-pair health (T8); --failback DR-ID records original-pair health
  P4-S02  Confirm recovery transaction/readback (T9); --failback DR-ID offers return-path sign-off
  P4-G4   Record formal service-restored approval and T10 (local attestation)
  P5      Automatically package local journals with SHA256 manifest; omit deployment logs (no prompts/upload)

Run or resume recovery through T10 and local packaging: bb3-run.sh S3
Start a separate new recovery deliberately: bb3-run.sh S3 --new
Run guided failback for an explicit completed recovery: bb3-run.sh S3 --failback DR-ID
Default checks saved progress and offers confirmed continuation; new runs use P0-S01 through P5.
Run only the RDS recovery phase: bb3-run.sh S3 --to P2-S09
Run selected steps only:  bb3-run.sh S3 --only P0-S01,P0-S02,P0-S03
Run an inclusive range:   bb3-run.sh S3 --from P2-S06 --to P2-S09
Inspect a range only:     bb3-run.sh S3 --from P3-S01 --to P4-S02 --list
Every executed step shows What/Expected descriptions by default; --verbose remains accepted for compatibility.
Run from the repository root. Approval gates are unchanged.
Direct underlying scripts remain available for overrides.
EOF
}

usage() {
  cat >&2 <<'EOF'
Usage:
  bash iac/lab/bb3-db/bb3-run.sh --list
  bash iac/lab/bb3-db/bb3-run.sh S3 [--only P0-S01,P0-S02 [step arguments]]
  bash iac/lab/bb3-db/bb3-run.sh S3 [--new | --from STEP] [--to STEP] [--list] [--verbose]
  bash iac/lab/bb3-db/bb3-run.sh S3 --failback DR-ID [--list]
EOF
  list_steps >&2
  exit 2
}

on_interrupt() {
  if [[ "$PROGRESS_ENABLED" == true ]]; then
    echo >&2
    echo 'Progress saved. Rerun this main command for a checked, confirmed continuation:' >&2
    print_main_command >&2
  fi
  if [[ -n "$FAILBACK_RUN" ]]; then
    printf '\nInterrupted guided failback at %s for %s. Inspect saved journals/live state before retrying; do not restart recovery.\n' \
      "$CURRENT_STEP" "$FAILBACK_RUN" >&2
    printf 'After reviewing whether the action completed, the exact single-step command is:\n' >&2
    printf 'bash iac/lab/bb3-db/bb3-run.sh S3 --only %q' "$CURRENT_STEP" >&2
    printf ' %q' "${CURRENT_ARGS[@]}" >&2
    printf '\n' >&2
    exit 130
  fi
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
      printf '\nInterrupted during %s. After reviewing saved/live state, the manual single-step command is:\n' "${CURRENT_STEP:-the current step}" >&2
      printf 'bash iac/lab/bb3-db/bb3-run.sh %s --only %s\n' "${SCENARIO:-S3}" "${CURRENT_STEP:-P1-S02}" >&2
      ;;
  esac
  exit 130
}
trap on_interrupt INT

on_error() {
  local exit_code=$?
  trap - ERR
  if [[ "$PROGRESS_ENABLED" == true && -n "$CURRENT_STEP" ]]; then
    printf '\nStopped at %s (%s). No later steps were run.\n' "$CURRENT_STEP" "${CURRENT_ACTION:-recovery}" >&2
    echo 'Rerun this main command to check saved progress and confirm continuation:' >&2
    print_main_command >&2
  fi
  exit "$exit_code"
}
set -E
trap on_error ERR

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
    --new)
      [[ -z "$ONLY$FROM$TO$FAILBACK_RUN" && "$NEW_RUN" == false ]] || usage
      NEW_RUN=true; shift ;;
    --list) LIST_ONLY=true; shift ;;
    --verbose) shift ;;
    --failback)
      [[ $# -ge 2 ]] || usage
      [[ "$2" =~ ^DR-[A-Za-z0-9_-]{1,120}$ ]] || {
        echo 'Failback requires an actual DR- run ID, not the literal {{COMPLETED_CUTOVER_DR_ID}} placeholder. Use the run ID shown by P4-G4 or saved-progress output.' >&2
        exit 2
      }
      [[ -z "$FAILBACK_RUN$ONLY$FROM$TO" && "$NEW_RUN" == false ]] || usage
      FAILBACK_RUN="$2"; shift 2 ;;
    --from)
      [[ $# -ge 2 && -n "$2" && -z "$FROM" && -z "$ONLY$FAILBACK_RUN" && "$NEW_RUN" == false ]] || usage
      FROM="$2"; shift 2 ;;
    --to)
      [[ $# -ge 2 && -n "$2" && -z "$TO" && -z "$ONLY$FAILBACK_RUN" && "$NEW_RUN" == false ]] || usage
      TO="$2"; shift 2 ;;
    --only)
      [[ $# -ge 2 && -n "$2" && -z "$ONLY$FROM$TO$FAILBACK_RUN" && "$NEW_RUN" == false ]] || usage
      ONLY="$2"; shift 2
      STEP_ARGS=("$@")
      for argument in "${STEP_ARGS[@]}"; do
        [[ "$argument" != --from && "$argument" != --to && "$argument" != --only ]] || usage
      done
      break ;;
    *) usage ;;
  esac
done

if [[ -n "$FAILBACK_RUN" && "$LIST_ONLY" == true ]]; then
  printf 'Guided failback for %s (no actions run):\n' "$FAILBACK_RUN"
  cat <<'EOF'
  FB-01  P3-S02 --preview: review saved original return endpoints
  FB-02  P3-S01: fence restored DBs and confirm sessions closed
  FB-03  P3-S02 --apply: approve endpoint return to originals
  FB-04  P3-S01 --release-quarantine: verify restored fence, release originals
  FB-05  P3-S03: confirm approved external app deployment/convergence
  FB-05  P4-S01: confirm original-pair app health
  FB-06  P4-S02: confirm transaction/readback and offer explicit failback sign-off
Retirement is not automatic; resource deletion requires separate approval.
EOF
  exit 0
fi

ALL_STEPS=(P0-S01 P0-S02 P0-S03 P1-S01-1 P1-S01-2 P2-S00 P2-S01 P2-S02 P2-S03 P2-S04 P2-S05 P2-S06 P2-S07 P2-S08 P2-S09 P3-S01 P3-S02 P3-S03 P4-S01 P4-S02 P4-G4 P5)
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
  STEPS=("${ALL_STEPS[@]}")
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

read_configuration() {
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
}

load_environment() {
  read_configuration
  CALLER="$(aws --profile "$PROFILE" --region "$REGION" --no-cli-pager sts get-caller-identity --query Account --output text)"
  [[ "$CALLER" == "$ACCOUNT" ]] || { echo 'AWS caller does not match the configured sandbox account.' >&2; return 2; }
}

print_main_command() {
  if [[ -n "$FAILBACK_RUN" ]]; then
    printf 'bash iac/lab/bb3-db/bb3-run.sh S3 --failback %s\n' "$FAILBACK_RUN"
  else
    echo 'bash iac/lab/bb3-db/bb3-run.sh S3'
  fi
}

progress_context() {
  local config_digest
  read_configuration
  if command -v sha256sum >/dev/null 2>&1; then
    config_digest="$(awk '$0 !~ /^export BB3_RTO_TARGET_MIN=[0-9]+([.][0-9]+)?[[:space:]]*$/' "$CONFIG" | sha256sum | awk '{print $1}')"
  else
    config_digest="$(awk '$0 !~ /^export BB3_RTO_TARGET_MIN=[0-9]+([.][0-9]+)?[[:space:]]*$/' "$CONFIG" | shasum -a 256 | awk '{print $1}')"
  fi
  jq -cn --arg root "$ROOT" --arg ledger "$LEDGER" --arg account "$ACCOUNT" --arg region "$REGION" \
    --arg environment "${ENV:-}" --arg run "${FAILBACK_RUN:-${BB3_DR_ID:-}}" \
    --arg primary "${BB3_SOURCE_PRIMARY_ID:-}" --arg replica "${BB3_SOURCE_REPLICA_ID:-}" \
    --arg targetPrimary "${BB3_RESTORE_TARGET_PRIMARY_ID:-}" --arg targetReplica "${BB3_RESTORE_TARGET_REPLICA_ID:-}" \
    --arg snapshot "${BB3_SNAPSHOT_ID:-}" --arg t0At "${BB3_T0_AT:-}" --arg t0Ref "${BB3_T0_EVIDENCE_REF:-}" \
    --arg configDigest "$config_digest" \
    '{root:$root,ledger:$ledger,account:$account,region:$region,environment:$environment,runId:$run,
      primary:$primary,replica:$replica,targetPrimary:$targetPrimary,targetReplica:$targetReplica,snapshot:$snapshot,
      t0At:$t0At,t0Ref:$t0Ref,configDigest:$configDigest}'
}

progress_update() {
  [[ "$PROGRESS_ENABLED" == true ]] || return 0
  local context
  context="$(progress_context)"
  python3 "$HERE/runner-progress.py" "$1" --context "$context" --mode "$PROGRESS_MODE" \
    --step "${CURRENT_ACTION:-$CURRENT_STEP}"
}

prepare_progress() {
  [[ -z "$ONLY$FROM$TO" ]] || return 0
  local context plan next reply mode inventory start
  context="$(progress_context)"
  git -C "$ROOT" check-ignore -q "$LEDGER/.runner-check.json" \
    || { echo 'Runner progress must be Git-ignored.' >&2; return 2; }
  [[ -z "${AWS_ACCESS_KEY_ID:-}${AWS_SECRET_ACCESS_KEY:-}${AWS_SESSION_TOKEN:-}" ]] \
    || { echo 'Unset exported AWS credentials.' >&2; return 2; }
  [[ -z "$FAILBACK_RUN" ]] || PROGRESS_MODE=failback
  if [[ "$NEW_RUN" == true ]]; then
    python3 "$HERE/runner-progress.py" reset --context "$context" --mode recovery
    PROGRESS_ENABLED=true
    return 0
  fi
  plan="$(python3 "$HERE/runner-progress.py" plan --context "$context" --mode "$PROGRESS_MODE")"
  if [[ "$(jq -r '.next' <<< "$plan")" == probe ]]; then
    echo 'An RDS submission was interrupted. Checking target identity/tags read-only before choosing a retry or waiter.'
    load_environment
    inventory="$(aws --profile "$PROFILE" --region "$REGION" --no-cli-pager rds describe-db-instances --output json | \
      jq -ce '.DBInstances | select(type=="array")')"
    plan="$(python3 "$HERE/runner-progress.py" plan --context "$context" --mode "$PROGRESS_MODE" --inventory "$inventory")"
  fi
  [[ "$(jq -r '.existing' <<< "$plan")" == true ]] || { PROGRESS_ENABLED=true; return 0; }
  mode="$(jq -r '.mode' <<< "$plan")"
  next="$(jq -r '.next // empty' <<< "$plan")"
  printf '\nSaved %s progress for run: %s\n' "$mode" "$(jq -r '.runId // "not allocated yet"' <<< "$plan")"
  echo 'Saved evidence/checkpoints are local progress, not independent application proof. Existing live checks and typed approvals still apply.'
  if [[ -z "$next" ]]; then
    echo 'This workflow is already complete; no steps will be repeated.'
    if [[ "$mode" == recovery ]]; then
      printf 'Next phase, after its separate approvals: bash iac/lab/bb3-db/bb3-run.sh S3 --failback %s\n' "$(jq -r '.runId' <<< "$plan")"
      echo 'For a separate new incident, use: bash iac/lab/bb3-db/bb3-run.sh S3 --new'
    else
      printf 'Retirement remains separately approved: bash iac/lab/bb3-db/retire-restored.sh --failback %s\n' "$(jq -r '.runId' <<< "$plan")"
    fi
    exit 0
  fi
  printf 'Suggested continuation: %s\n' "$next"
  if [[ "$mode" == failback ]]; then
    case "$next" in
      preview) echo 'Step: P3-S02 --preview (read-only return-endpoint review)' ;;
      fence) echo 'Step: P3-S01 (fence restored DBs and confirm sessions closed)' ;;
      endpoints) echo 'Step: P3-S02 --apply (guarded endpoint return)' ;;
      release) echo 'Step: P3-S01 --release-quarantine (release original DBs)' ;;
      deployment) echo 'Step: P3-S03 (manual original-path deployment confirmation)' ;;
      health) echo 'Step: P4-S01 (original-path application health)' ;;
      signoff) echo 'Step: P4-S02 (transaction and explicit failback sign-off)' ;;
    esac
  fi
  printf 'Completed checkpoint actions: %s\n' "$(jq -r '.completed | if length==0 then "none (legacy journals checked)" else join(", ") end' <<< "$plan")"
  if [[ "$mode" == failback ]]; then
    FAILBACK_RUN="$(jq -r '.runId' <<< "$plan")"
    printf 'Continuation command: '; print_main_command
  else
    printf 'Equivalent continuation: bash iac/lab/bb3-db/bb3-run.sh S3 --from %s --to P5\n' "$next"
  fi
  [[ -t 0 ]] || { echo 'Interactive confirmation required; no continuation was run.' >&2; return 2; }
  bb3_prompt_read reply 'Continue from the suggested action? [Enter=yes, n=cancel]: '
  case "$reply" in ''|y|Y|yes|YES) ;; *) echo 'Continuation cancelled; no steps run.'; exit 0 ;; esac
  PROGRESS_MODE="$mode"
  PROGRESS_ENABLED=true
  context="$(progress_context)"
  python3 "$HERE/runner-progress.py" adopt --context "$context" --mode "$mode" --step "$next"
  if [[ "$mode" == failback ]]; then
    NEXT_ACTION="$next"
  else
    start="$(step_index "$next")"
    STEPS=("${ALL_STEPS[@]:start}")
  fi
}

wait_for_target() {
  local target="$1" description="$2"
  load_environment
  printf '%s: waiting for %s (%s) to become available. Press Ctrl+C to stop; the resume command will be printed.\n' \
    "$CURRENT_STEP" "$target" "$description"
  bb3_wait "$CURRENT_STEP: waiting for $description" aws --profile "$PROFILE" --region "$REGION" --no-cli-pager rds wait db-instance-available \
    --db-instance-identifier "$target"
  printf '%s: %s is available.\n' "$CURRENT_STEP" "$target"
}

step_preview() {
  local action expected what_label='  What:' expected_label='  Expected:'
  local step="$1" argument failback=false apply=false fence_action=fence
  shift
  if [[ "$step" == P3-S02 && -z "$ONLY" && $# == 0 ]]; then apply=true; fi
  for argument in "$@"; do
    case "$argument" in
      --failback) failback=true ;;
      --apply) apply=true ;;
      --preview) apply=false ;;
      --release-quarantine) fence_action=release ;;
      --cleanup-failback-quarantine) fence_action=cleanup ;;
    esac
  done
  case "$step" in
    P0-S01) action='Discover and save the source pair, snapshot, and restore targets.'; expected='A reviewed source/replica selection and deterministic restore target IDs are saved.' ;;
    P0-S02) action='Capture the original primary/replica API baseline and checksums.'; expected='A complete, checksum-verified baseline matching the selected DBs is recorded before the quarantine.' ;;
    P0-S03) action='Simulate app failure by cutting off new DB traffic: attach the run-scoped no-ingress SG to both source DBs.'; expected='Both attachments are active and actual app/monitor failure evidence is recorded. Existing sessions are not closed by an SG change; original SG sets remain in the baseline.' ;;
    P1-S01-1) action='Record the service-impact time T0 from app/monitor evidence; Enter defaults to current UTC.'; expected='UTC T0 and its required evidence reference are saved for the existing P0 run ID.' ;;
    P1-S01-2) action='Record declaration T1 for the selected S3 snapshot recovery; no scenario reselection.'; expected='T1 is not earlier than T0; T1 evidence is required if backfilled; the existing P0 run ID is declared for S3.' ;;
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
    P3-S01) action='Verify the original source pair quarantine and confirm existing sessions are closed.'; expected='Both original source DBs remain isolated by the verified P0 quarantine; this recovery step does not change source SGs or stop DBs.' ;;
    P3-S02) action='Update or verify the app secret endpoint pair.'; expected='Both endpoints match the selected restored pair; any write requires the matching verified fence.' ;;
    P3-S03) action='Run guarded automatic/guided deployment over local SSH, or confirm a manual deployment.'; expected='Only dev/uat hosts are supported. Automatic/guided SSH requires a typed DEPLOY-ENV approval; owner review and sanitized evidence confirmation are still required. --failback DR-ID records supplemental return-path evidence.' ;;
    P4-S01) action='Confirm app health on the selected endpoint pair.'; expected='Recovery mode records T8; --failback DR-ID records separate original-pair health evidence and actual UTC time.' ;;
    P4-S02) action='Confirm a successful business transaction and readback.'; expected='Recovery mode records T9; --failback DR-ID records or reuses a separate transaction and offers explicit owner sign-off, not deletion approval.' ;;
    P4-G4) action='Review saved recovery evidence and record formal service-restored approval.'; expected='Validated T10, approver/role and evidence references are saved locally after typed approval; T8/T9 are preserved.' ;;
    P5) action='Automatically package validated local recovery journals without additional input.'; expected='Use the saved closeout approver and default local directory; create a frozen snapshot, SHA256 archive and receipt. Deployment logs are omitted; no automatic review, AWS verification or upload is claimed.' ;;
    *) action='Run the selected BB3 step.'; expected='Follow the step output and approval prompts.' ;;
  esac
  if [[ "$failback" == true ]]; then
    case "$step" in
      P3-S01)
        case "$fence_action" in
          release)
            action='Release the original DB pair quarantine after endpoint failback.'
            expected='Freshly verify restored-pair isolation and session-closure evidence, restore the saved original SGs after typed approval, then remove the original quarantine SG. Keep the restored pair fenced.' ;;
          cleanup)
            action='Delete only the detached restored-pair failback quarantine SG.'
            expected='Verify completed failback app attestations, run ownership and no DB/ENI attachments before typed cleanup approval. This action never retires DBs or deletes snapshots/backups.' ;;
          fence)
            action='Fence the restored DB pair for failback and confirm existing sessions are closed.'
            expected='After approval, create or resume the restored-pair no-ingress quarantine and verify its attachments. Session closure is separately owner-confirmed; an SG change does not close existing sessions. Keep originals isolated until approved release.' ;;
        esac ;;
      P3-S02)
        if [[ "$apply" == true ]]; then
          action='Apply failback: return both app secret endpoints from the restored pair to the original pair.'
          expected='Require the matching restored-pair fence/session record and typed FAILBACK-ENDPOINTS approval before updating only endpoint keys. No data reconciliation or application deployment is performed.'
        else
          action='Preview failback: show current restored endpoints and the saved original return endpoints (read-only).'
          expected='Review the original primary/replica destination. No secret write, fencing, application deployment or data reconciliation occurs; this preview runs before the restored-pair fence.'
        fi ;;
      P3-S03)
        action='Run guarded automatic/guided SSH deployment or confirm manual deployment on the original DB endpoint pair.'
        expected='Dev/uat SSH requires typed approval and owner-confirmed convergence. A configured Docker mock rehearses only and leaves P3-S03 pending. Review/capture sanitized failback evidence without changing recovery milestones.' ;;
      P4-S01)
        action='Record app-owner health confirmation on the original primary/replica endpoint pair.'
        expected='Require matching failback/deployment/fence journals and collect actual successful health-check UTC time and evidence. Save supplemental failback health; original recovery T8 and RTO remain unchanged.' ;;
      P4-S02)
        action='Record or reuse the original-path business transaction/readback and offer explicit failback sign-off.'
        expected='Preserve the saved transaction reference/time on retry. Review actual deployment/health/business evidence and require matching-owner SIGN-OFF-FAILBACK approval. Recovery T9 stays unchanged; resource retirement needs separate approval.' ;;
    esac
  fi
  if [[ -t 1 && -z "${NO_COLOR+x}" && "${TERM:-dumb}" != dumb ]]; then
    printf '\033[1;36m%s\033[0m %s\n\033[1;36m%s\033[0m %s\n' \
      "$what_label" "$action" "$expected_label" "$expected"
  else
    printf '%s %s\n%s %s\n' "$what_label" "$action" "$expected_label" "$expected"
  fi
}

run_step() {
  local context inventory decision
  CURRENT_STEP="$1"
  shift
  CURRENT_ARGS=("$@")
  progress_update start
  if [[ "$PROGRESS_ENABLED" == true && -z "$CURRENT_ACTION" ]]; then
    case "$CURRENT_STEP" in
      P2-S03)
        read_configuration
        wait_for_target "${BB3_RESTORE_TARGET_PRIMARY_ID:-}" 'primary readiness before hardening/revalidation' ;;
      P2-S07)
        read_configuration
        wait_for_target "${BB3_RESTORE_TARGET_REPLICA_ID:-}" 'replica readiness before hardening/revalidation' ;;
    esac
  fi
  if [[ "$PROGRESS_ENABLED" == true && -z "$CURRENT_ACTION" && ( "$CURRENT_STEP" == P2-S01 || "$CURRENT_STEP" == P2-S05 ) ]]; then
    load_environment
    context="$(progress_context)"
    inventory="$(aws --profile "$PROFILE" --region "$REGION" --no-cli-pager rds describe-db-instances --output json | \
      jq -ce '.DBInstances | select(type=="array")')"
    decision="$(python3 "$HERE/runner-progress.py" plan --context "$context" --mode recovery --inventory "$inventory")"
    if [[ "$(jq -r '.next' <<< "$decision")" == P2-S02 || "$(jq -r '.next' <<< "$decision")" == P2-S06 ]]; then
      printf '%s: target already exists with matching run tag/topology; not resubmitting. Continue with its waiter.\n' "$CURRENT_STEP"
      progress_update 'done'
      return 0
    fi
  fi
  if [[ -t 1 && -z "${NO_COLOR+x}" && "${TERM:-dumb}" != dumb ]]; then
    printf '\n\033[1;35m== %s ==\033[0m\n' "$CURRENT_STEP"
  else
    printf '\n== %s ==\n' "$CURRENT_STEP"
  fi
  step_preview "$CURRENT_STEP" "$@"
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
      if [[ -z "$ONLY" && $# == 0 ]]; then
        echo 'Recovery sequence selects --apply; fence verification and explicit endpoint approval are still required.'
        bash "$HERE/secret-endpoints.sh" --apply "$@"
      else
        bash "$HERE/secret-endpoints.sh" "$@"
      fi
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
    P4-G4)
      bash "$HERE/closeout.sh" declare "$@"
      ;;
    P5)
      bash "$HERE/closeout.sh" package "$@"
      ;;
    *) echo "Unknown BB3 step ID: $CURRENT_STEP" >&2; list_steps >&2; return 2 ;;
  esac
  progress_update 'done'
}

prepare_progress

if [[ -n "$FAILBACK_RUN" ]]; then
  printf 'Guided failback for completed recovery: %s\n' "$FAILBACK_RUN"
  echo 'Prerequisite: approved failback window and data-owner reconciliation/data-loss decision. Endpoint return does not copy writes.'
  echo 'Pause/drain app consumers before confirming the restored-pair fence. External deployment remains manual.'
  continue_actions=false
  for CURRENT_ACTION in preview fence endpoints release deployment health signoff; do
    [[ "$CURRENT_ACTION" != "$NEXT_ACTION" ]] || continue_actions=true
    [[ "$continue_actions" == true ]] || continue
    case "$CURRENT_ACTION" in
      preview) run_step P3-S02 --failback "$FAILBACK_RUN" --preview ;;
      fence) run_step P3-S01 --failback "$FAILBACK_RUN" ;;
      endpoints) run_step P3-S02 --failback "$FAILBACK_RUN" --apply ;;
      release) run_step P3-S01 --failback "$FAILBACK_RUN" --release-quarantine ;;
      deployment) run_step P3-S03 --failback "$FAILBACK_RUN" ;;
      health) run_step P4-S01 --failback "$FAILBACK_RUN" ;;
      signoff) run_step P4-S02 --failback "$FAILBACK_RUN" ;;
    esac
  done
  echo 'Guided failback steps finished. Completion requires the saved app-owner sign-off; declining it leaves sign-off pending.'
  echo 'Resource retirement remains separately approved; original recovery T8/T9 and P5 package are unchanged.'
  CURRENT_STEP=''
  exit 0
fi

{
  for CURRENT_STEP in "${STEPS[@]}"; do
    if [[ "$ONLY" != '' ]]; then
      run_step "$CURRENT_STEP" "${STEP_ARGS[@]}"
    else
      run_step "$CURRENT_STEP"
    fi
  done
  if [[ "$CURRENT_STEP" == P2-S09 ]]; then
    cat <<'EOF'

RDS target inspection finished at P2-S09. This selection stops before application recovery.
RDS available/configuration checks do not prove application recovery.
Next: verify isolation/session closure and collect cutover approval before changing endpoints:
  bash iac/lab/bb3-db/bb3-run.sh S3 --only P3-S01
Continue the remaining recovery/closeout steps with all approval gates:
  bash iac/lab/bb3-db/bb3-run.sh S3 --from P3-S01 --to P5
Plain S3 checks saved progress and offers confirmed continuation. Only S3 --new starts a separate drill.
EOF
  fi
  CURRENT_STEP=''
  exit 0
}