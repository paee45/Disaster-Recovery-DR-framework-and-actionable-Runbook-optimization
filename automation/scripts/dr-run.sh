#!/usr/bin/env bash
# dr-run.sh — run a DR runbook STEP BY STEP, with the runbook's step IDs, live output and evidence as it goes.
#
#   source env/uat.env
#   ./automation/scripts/dr-run.sh S3                      # RB-<ENV>-S3 snapshot restore, from pre-flight to evidence
#   ./automation/scripts/dr-run.sh S4                      # RB-<ENV>-S4 point-in-time restore
#   ./automation/scripts/dr-run.sh S3 --list               # the steps, their IDs, kind and command (no AWS access)
#   ./automation/scripts/dr-run.sh S3 --dry-run            # print every step + command it WOULD run, change nothing
#   ./automation/scripts/dr-run.sh S3 --resume <DR_ID>     # continue an interrupted run (same evidence folder + timeline)
#
# For every step you see, as it happens:
#   ▶ header       ID, kind (check / change / input / gate / manual), title, the exact command
#   │ output       live, indented; also saved to evidence/<DR_ID>/steps/<ID>.log (passwords redacted)
#   result         ✅ / ❌ / ➖ (N/A) with the duration
#   🕒 timeline    the markers the step wrote (T0…T10, RPO, DECISION, PHASE_*, RUN_STEP_*)
#   📄 evidence    every file the step created or changed in the evidence folder
# At each phase end: elapsed vs budget (dr_phase) and the evidence folder is synced to the WORM bucket.
# The whole session is in evidence/<DR_ID>/run.log; the step table in run-report.md; progress in run-state.tsv.
#
# Options:
#   --only ID,ID   --skip ID,ID   --from ID   --to ID      choose steps (e.g. --to P2-S05 = restore + verify, no cutover)
#   --on-fail ask|stop|continue   default: ask on a terminal ([r]etry [s]kip [a]bort), otherwise STOP.
#                  A step whose prerequisite failed is BLOCKED, never run (no cutover on an unvalidated DB).
#   -q             quiet: no live output on screen (still in the logs)
# Gates (⛳) wait for a typed GO + approver name(s) and record DECISION in the timeline (approvals/<ID>.txt).
# Inputs are asked once and saved for --resume (run-vars.env); set them in advance to skip the prompt:
#   T0_AT (first error, UTC ISO; empty = now) · SNAPSHOT_ID (S3; default newest automated) · BAD_TS or RESTORE_TS (S4)
#   RESTORE_MODE A|B (S4) · RESTORED_DB · FENCE readonly|skip · E2E_REF (test transaction id)
# PROD: every change step asks for the typed 'prod' confirmation first (dr_confirm).
# Local test bed only: DR_RUN_GATES=auto answers gates/inputs automatically (refused in any other env);
#   DR_RUN_AUTO_NO=<gate id,…> answers NO at those gates (tests the stop + resume path).
set -o pipefail   # no -u: an unset variable inside a step must fail THAT step, not kill the runner mid-run
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"; S="$HERE"

SC=""; ONLY=""; SKIP=""; FROM=""; TO=""; ON_FAIL=""; QUIET=0; LIST=0; DRYRUN=0; RESUME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    S3|S4) SC="$1"; shift ;;
    --only) ONLY=",$2,"; shift 2 ;;
    --skip) SKIP=",$2,"; shift 2 ;;
    --from) FROM="$2"; shift 2 ;;
    --to) TO="$2"; shift 2 ;;
    --on-fail) ON_FAIL="$2"; shift 2 ;;
    --resume) RESUME="$2"; shift 2 ;;
    -q|--quiet) QUIET=1; shift ;;
    --list) LIST=1; shift ;;
    --dry-run) DRYRUN=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1 (see --help)"; exit 2 ;;
  esac
done
[[ -n "$SC" ]] || { echo "usage: $0 S3|S4 [--list|--dry-run|--resume DR_ID|--only|--skip|--from|--to|--on-fail|-q]"; exit 2; }

# ───────────────────── step catalogue: ID | kind | title | command (as written in the runbook) ─────────────────────
# kind: check (read-only) · change (modifies AWS/K8s) · input (asks a value) · gate (GO/NO + names) · manual (people do it)
COMMON_PRE=(
  "P0-S01|check|environment check: variables, tools, identity guard|dr-env-check.sh $SC"
  "P0-S02|check|pre-flight: restore window, snapshots, Secret, Reloader|dr-preflight.sh restore"
  "P0-S03|input|instance names: OLD_DB (replaced) and RESTORED_DB (new)|export OLD_DB=\$PRIMARY_DB RESTORED_DB=\$PRIMARY_DB-$([[ $SC == S4 ]] && echo p || echo r)<YYYYMMDDHHMM>"
  "P1-S01|input|open the incident: T0 (first error) + T1 (now)|dr_mark T0 --at <ts>; dr_mark T1"
)
CUTOVER_STEPS=(
  "FENCE|change|fence the old instance (CP-04 F1) — N/A if stopped/unreachable|dr-fence-instance.sh readonly \$OLD_DB"
  "APPLY|change|CUTOVER: write the new endpoint into the Secret, Reloader restarts the pods (CP-01)|dr-secret-cutover.sh apply  [+ CUTOVER_SECRET=ro … apply]"
  "AFTER|change|resume CronJobs + no consumer left on the old Secret (stale check / restart-stale)|dr-eks-rollout.sh resume-cronjobs; dr-eks-rollout.sh check || restart-stale"
)
if [[ "$SC" == S3 ]]; then
  STEPS=("${COMMON_PRE[@]}"
    "P1-S02|input|choose the snapshot (newest automated unless told otherwise)|dr-restore.sh list-snapshots \$PRIMARY_DB; export SNAPSHOT_ID=…"
    "P1-G1|gate|GO: accept the loss of data after the snapshot time → T2|dr_mark DECISION …; dr_mark T2"
    "P2-S00|check|plan: restore request built from the baseline (no change)|dr-restore.sh plan snapshot \$SNAPSHOT_ID \$RESTORED_DB"
    "P2-S01|change|restore the snapshot with every setting from the baseline → T4|dr-restore.sh snapshot \$SNAPSHOT_ID \$RESTORED_DB"
    "P2-S02|change|while it restores: consumers inventory + suspend CronJobs|dr-eks-rollout.sh inventory; dr-eks-rollout.sh suspend-cronjobs"
    "P2-S03|check|wait until available → T5|dr-restore.sh wait \$RESTORED_DB"
    "P2-S04|change|harden: converge to the baseline, then validate → VALIDATED|dr-restore.sh harden \$RESTORED_DB"
    "P2-S05|check|DB verification: app login (fix-password if needed), pg_settings, SQL verify, row counts|dr-secret-cutover.sh precheck; dr-restore.sh validate-pg; psql -f 20-postfailover-verify.sql; dr-verify.sh compare-counts"
    "P3-G0|gate|GO for the cutover (restored DB VALIDATED and verified)|dr_mark DECISION …"
    "${CUTOVER_STEPS[0]/FENCE/P3-S01}" "${CUTOVER_STEPS[1]/APPLY/P3-S02}" "${CUTOVER_STEPS[2]/AFTER/P3-S03}"
    "P4-S01|check|app sessions on the new DB, none left on the old|dr-verify.sh connections"
    "P4-S02|input|E2E: dashboard + one test transaction (playbook) → T9|dr_mark T9 \"e2e ref=…\""
    "P4-G4|gate|declare services restored → T10 + phase summary|dr_mark T10; dr_summary"
    "P5-S01|change|evidence bundle: KPIs, CloudTrail, RDS events, SHA-256 manifest → WORM bucket|dr-collect-evidence.sh")
  declare -A NEEDS=([P1-G1]="P0-S03 P1-S02" [P2-S00]=P1-S02 [P2-S01]="P1-G1 P2-S00" [P2-S03]=P2-S01 [P2-S04]=P2-S03 [P2-S05]=P2-S04
    [P3-G0]="P2-S04 P2-S05" [P3-S01]=P3-G0 [P3-S02]="P3-G0 P3-S01" [P3-S03]=P3-S02 [P4-S01]=P3-S02 [P4-S02]=P3-S02 [P4-G4]=P4-S02)
  declare -A PSTART=([P1-S01]="prepare 3" [P2-S01]="restore 12" [P2-S04]="harden 4" [P3-S01]="cutover 5" [P4-S01]="app-verify 5" [P5-S01]="close 1")
  declare -A PEND=([P1-G1]="prepare 3" [P2-S03]="restore 12" [P2-S05]="harden 4" [P3-S03]="cutover 5" [P4-G4]="app-verify 5" [P5-S01]="close 1")
  declare -A COND=()
else
  STEPS=("${COMMON_PRE[@]}"
    "P1-S02|manual|stop the damage (pause the job / migration / loader; F1 on OLD_DB if ongoing)|dr_mark DAMAGE_STOPPED"
    "P1-S03|input|restore point: BAD_TS → RESTORE_TS = BAD_TS − 1 s, inside the restore window|dr-restore.sh list-snapshots \$PRIMARY_DB; export RESTORE_TS=…"
    "P1-S04|input|mode A (restored DB becomes primary) or B (repair data on the primary)|dr_mark DECISION mode=…"
    "P1-G1|gate|GO with RESTORE_TS and the loss window → T2|dr_mark DECISION …; dr_mark T2"
    "P2-S00|check|plan: PITR request built from the baseline (no change)|dr-restore.sh plan pitr \$PRIMARY_DB \$RESTORED_DB \$RESTORE_TS"
    "P2-S01|change|point-in-time restore with every setting from the baseline → T4|dr-restore.sh pitr \$PRIMARY_DB \$RESTORED_DB \$RESTORE_TS"
    "P2-S02|change|wait until available (→ T5), then harden + validate → VALIDATED|dr-restore.sh wait \$RESTORED_DB; dr-restore.sh harden \$RESTORED_DB"
    "P2-S03|check|restore-point check: the bad change is absent (05-restore-point-check.sql)|psql \"\$TARGET_DSN\" -v cutoff=\$RESTORE_TS -f 05-restore-point-check.sql"
    "P2-G3|gate|restore point signed off (DBA + QA)|dr_mark DECISION …"
    "P3B-S01|manual|MODE B: export the rows from RESTORED_DB, apply the reviewed repair on PRIMARY_DB (DBA)|pg_dump --data-only -t … / \\copy; repair script in one transaction"
    "P3A-S01|check|MODE A: parity — all RDS settings + pg_settings equal to the source (CP-03)|dr-restore.sh validate \$RESTORED_DB; dr-restore.sh validate-pg"
    "P3A-G0|gate|MODE A: GO for the cutover|dr_mark DECISION …"
    "${CUTOVER_STEPS[0]/FENCE/P3A-S02}"
    "P3A-S03|change|MODE A: CUTOVER (CP-01): inventory, suspend CronJobs, app login, write endpoint, Reloader, resume, stale check|dr-eks-rollout.sh inventory/suspend-cronjobs; dr-secret-cutover.sh precheck|fix-password; apply; resume-cronjobs; check"
    "P3A-S04|check|MODE A: app sessions on the new DB, none left on the old (CP-02)|dr-verify.sh connections"
    "P3A-S05|input|MODE A: E2E: dashboard + one test transaction → T9|dr_mark T9 \"e2e ref=…\""
    "P3A-G5|gate|MODE A: declare services restored → T10 + phase summary|dr_mark T10; dr_summary"
    "P4-S01|change|evidence bundle (RPO_RESTORE_TS) → WORM bucket (CP-05)|dr-collect-evidence.sh")
  declare -A NEEDS=([P1-G1]="P0-S03 P1-S03 P1-S04" [P2-S00]=P1-S03 [P2-S01]="P1-G1 P2-S00" [P2-S02]=P2-S01 [P2-S03]=P2-S02 [P2-G3]=P2-S03
    [P3B-S01]=P2-G3 [P3A-S01]="P2-S02 P2-G3" [P3A-G0]=P3A-S01 [P3A-S02]=P3A-G0 [P3A-S03]="P3A-G0 P3A-S02"
    [P3A-S04]=P3A-S03 [P3A-S05]=P3A-S03 [P3A-G5]=P3A-S05)
  declare -A PSTART=([P1-S01]="prepare 5" [P2-S01]="restore 16" [P3A-S02]="cutover 5" [P3A-S04]="app-verify 5" [P4-S01]="close 1")
  declare -A PEND=([P1-G1]="prepare 5" [P2-S02]="restore 16" [P3A-S03]="cutover 5" [P3A-G5]="app-verify 5" [P4-S01]="close 1")
  declare -A COND=([P3B-S01]=mode_b [P3A-S01]=mode_a [P3A-G0]=mode_a [P3A-S02]=mode_a [P3A-S03]=mode_a [P3A-S04]=mode_a
    [P3A-S05]=mode_a [P3A-G5]=mode_a)
fi
IDS=(); declare -A KIND=() TITLE=() CMD=() POS=()
for _l in "${STEPS[@]}"; do IFS='|' read -r _i _k _t _c <<<"$_l"; POS[$_i]=${#IDS[@]}; IDS+=("$_i"); KIND[$_i]=$_k; TITLE[$_i]=$_t; CMD[$_i]=$_c; done
for _i in "$FROM" "$TO"; do [[ -z "$_i" || -n "${POS[$_i]:-}" ]] || { echo "unknown step id: $_i (see --list)"; exit 2; }; done

icon() { case "$1" in check) echo "🔍";; change) echo "✏️ ";; input) echo "⌨️ ";; gate) echo "⛳";; manual) echo "🙋";; esac; }
if (( LIST )); then
  printf 'RB-*-%s step runner — %d steps\n' "$SC" "${#IDS[@]}"
  for i in "${IDS[@]}"; do
    printf '%-8s %s %-6s %s%s\n' "$i" "$(icon "${KIND[$i]}")" "${KIND[$i]}" "${TITLE[$i]}" "${NEEDS[$i]:+   (needs ${NEEDS[$i]})}"
    printf '%17s$ %s\n' "" "${CMD[$i]}"
  done; exit 0
fi

: "${DR_ENV:?source env/<env>.env first}"
if [[ "${DR_RUN_GATES:-ask}" == auto && "$DR_ENV" != local ]]; then echo "REFUSED: DR_RUN_GATES=auto is only for the local test bed (DR_ENV=local)"; exit 2; fi
AUTO=0; [[ "${DR_RUN_GATES:-ask}" == auto ]] && AUTO=1
has_tty() { (( AUTO == 0 )) && { : </dev/tty; } 2>/dev/null; }
tty_prompt() { sleep 0.3; printf '%s' "$1" >/dev/tty; }   # let the indented output reach the screen first
[[ -n "$ON_FAIL" ]] || { if has_tty; then ON_FAIL=ask; else ON_FAIL=stop; fi; }
[[ "$ON_FAIL" =~ ^(ask|stop|continue)$ ]] || { echo "--on-fail must be ask|stop|continue"; exit 2; }

# ───────────────────── selection ─────────────────────
selected() { # <id>
  local id="$1"
  [[ -n "$ONLY" && "$ONLY" != *",$id,"* ]] && return 1
  [[ -n "$SKIP" && "$SKIP" == *",$id,"* ]] && return 1
  [[ -n "$FROM" ]] && (( POS[$id] < POS[$FROM] )) && return 1
  [[ -n "$TO" ]] && (( POS[$id] > POS[$TO] )) && return 1
  return 0
}
if (( DRYRUN )); then
  echo "DRY RUN — $SC in env $DR_ENV: nothing is executed"
  for i in "${IDS[@]}"; do selected "$i" || continue
    printf '\n▶ %-8s %s %-6s %s\n   $ %s\n' "$i" "$(icon "${KIND[$i]}")" "${KIND[$i]}" "${TITLE[$i]}" "${CMD[$i]}"
    [[ -n "${PSTART[$i]:-}" ]] && echo "   ⏱  phase start: ${PSTART[$i]} min"
    [[ -n "${PEND[$i]:-}" ]] && echo "   ⏱  phase end:   ${PEND[$i]} min"
  done; exit 0
fi

# ───────────────────── start / resume the run ─────────────────────
cd "$ROOT" || exit 2
if [[ -n "$RESUME" ]]; then
  [[ -d "$ROOT/evidence/$RESUME" ]] || { echo "no evidence folder evidence/$RESUME to resume"; exit 2; }
  export DR_ID="$RESUME"
  # shellcheck source=/dev/null
  [[ -f "$ROOT/evidence/$RESUME/run-vars.env" ]] && source "$ROOT/evidence/$RESUME/run-vars.env"
fi
# one run = one DR_ID = one evidence folder evidence/<DR_ID> (an inherited DR_EVIDENCE_DIR is not used)
export DR_ID="${DR_ID:-DR-$(date -u +%Y%m%d-%H%M)-${DR_ENV}-${SC}}"
export DR_EVIDENCE_DIR="$ROOT/evidence/$DR_ID"
if [[ -z "$RESUME" && -f "$DR_EVIDENCE_DIR/run-state.tsv" ]]; then
  echo "DR_ID $DR_ID already has a run in $DR_EVIDENCE_DIR — continue it with --resume $DR_ID, or unset DR_ID for a new run"; exit 2; fi
# shellcheck source=dr-lib.sh
source "$S/dr-lib.sh" || exit 2
dr_init "$SC" || exit 2
RUNDIR="$DR_EVIDENCE_DIR"; mkdir -p "$RUNDIR/steps"
STATEF="$RUNDIR/run-state.tsv"; VARSF="$RUNDIR/run-vars.env"; RUNLOG="$RUNDIR/run.log"; REPORT="$RUNDIR/run-report.md"
MARKS="$(mktemp -d)"   # per-step time markers (find -newer) — kept out of the evidence folder
exec 3>&1 4>&2; exec > >(tee -a "$RUNLOG") 2>&1; TEE_PID=$!
[[ -n "$RESUME" ]] && dr_mark RUN_RESUME "runner=dr-run.sh $SC"

declare -A STATUS=() PREV=()
if [[ -f "$STATEF" ]]; then while IFS=$'\t' read -r i st _; do PREV[$i]="$st"; done < "$STATEF"; fi
SAVE_VARS=(OLD_DB RESTORED_DB SNAPSHOT_ID BAD_TS RESTORE_TS RESTORE_MODE FENCE E2E_REF T0_AT)
save_vars() {
  { for v in "${SAVE_VARS[@]}"; do [[ -n "${!v:-}" ]] && printf 'export %s=%q\n' "$v" "${!v}"; done
    for v in "${!DR_PHASE_START_@}"; do printf 'export %s=%q\n' "$v" "${!v}"; done; } > "$VARSF"
}

line() { printf '%s\n' "────────────────────────────────────────────────────────────────────────────────────────"; }
echo; line
echo "DR RUN $SC · env $DR_ENV · DR_ID $DR_ID · runner dr-run.sh · on-fail: $ON_FAIL$( (( AUTO )) && echo ' · gates: AUTO (local test)')"
echo "evidence: $RUNDIR   (run.log · steps/<ID>.log · run-report.md · timeline.jsonl)"
[[ -n "${EVIDENCE_BUCKET:-}" ]] && echo "synced at every phase end to s3://$EVIDENCE_BUCKET/$DR_ENV/$(date -u +%Y)/$DR_ID/"
line

# ───────────────────── helpers for inputs and gates (main shell: they set variables) ─────────────────────
# ask <VAR> <question> [default] — keep an existing value, else prompt (default on Enter); AUTO uses the default
ask() {
  local var="$1" q="$2" def="${3:-}" v
  if [[ -n "${!var:-}" ]]; then echo "$var=${!var}  (already set)"; return 0; fi
  if has_tty; then tty_prompt "   │ ⌨️  $q${def:+ [$def]}: "; read -r v </dev/tty; v="${v:-$def}"; echo "$var=$v"
  elif (( AUTO )) && [[ -n "$def" ]]; then v="$def"; echo "$var=$v  (auto)"
  else echo "$var is required: $q — set it in the environment (export $var=…) or run on a terminal"; return 1; fi
  [[ -n "$v" ]] || { echo "$var must not be empty"; return 1; }
  printf -v "$var" '%s' "$v"; export "${var?}"; save_vars
}
# gate <id> <question> — typed GO / NO + approver names → approvals/<id>.txt + DECISION marker
gate() {
  local id="$1" q="$2" ans who
  if (( AUTO )); then ans=GO; who="auto (local test bed)"; [[ ",${DR_RUN_AUTO_NO:-}," == *",$id,"* ]] && ans=NO
  elif has_tty; then
    tty_prompt "   │ ⛳ $q — type GO to continue or NO to stop: "; read -r ans </dev/tty
    tty_prompt "   │ approver name(s): "; read -r who </dev/tty
    echo "answer: $ans  approvers: $who"
  else echo "gate $id needs a terminal (a person must type GO)"; return 1; fi
  ans="${ans^^}"
  printf 'gate: %s\nquestion: %s\nanswer: %s\napprovers: %s\nrecorded_by: %s\nat: %s\n' "$id" "$q" "$ans" "${who:-?}" \
    "${DR_ACTOR:-?}" "$(date -u +%FT%TZ)" > "$DR_EVIDENCE_DIR/approvals/$id.txt"
  dr_mark DECISION "$id $ans by ${who:-?}: $q"
  [[ "$ans" == GO ]] || return 4
}
# manual <id> <what> — a person does it; record who confirmed
manual() {
  local id="$1" what="$2" who
  echo "🙋 $what"
  if (( AUTO )); then who="auto (local test bed)"
  elif has_tty; then tty_prompt "   │ done? type your name to confirm (empty = not done): "; read -r who </dev/tty; echo "confirmed by: ${who:-<nobody>}"
  else echo "manual step $id needs a terminal"; return 1; fi
  [[ -n "$who" ]] || { echo "not confirmed"; return 1; }
  dr_mark "MANUAL:$id" "done, confirmed by $who: $what"
}
db_status() { aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-instances --db-instance-identifier "$1" \
                --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo "not-found"; }
mode_a() { [[ "${RESTORE_MODE:-A}" == A ]]; }
mode_b() { [[ "${RESTORE_MODE:-A}" == B ]]; }
target() { dr_set_target "$RESTORED_DB" >/dev/null; [[ -n "${TARGET_DSN:-}" ]] || { echo "TARGET_DSN for $RESTORED_DB not available (app secret / endpoint)"; return 1; }; }
iso_ok() { [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}[T\ ][0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]+)?)?(Z|[+-][0-9]{2}:?[0-9]{2})?$ ]] && date -u -d "$1" +%s >/dev/null 2>&1; }
x() { echo "\$ $*"; "$@"; }   # show the exact command, then run it

# ───────────────────── steps ─────────────────────
s_P0-S01() { x "$S/dr-env-check.sh" "$SC"; }
s_P0-S02() { x "$S/dr-preflight.sh" restore; }
s_P0-S03() {
  ask OLD_DB "instance being replaced" "$PRIMARY_DB" || return 1
  ask RESTORED_DB "name of the new (restored) instance" "${PRIMARY_DB}-$([[ $SC == S4 ]] && echo p || echo r)$(date -u +%Y%m%d%H%M)" || return 1
  [[ "$RESTORED_DB" != "$OLD_DB" ]] || { echo "RESTORED_DB must differ from OLD_DB"; return 1; }
  echo "OLD_DB=$OLD_DB (status: $(db_status "$OLD_DB"))   RESTORED_DB=$RESTORED_DB (status: $(db_status "$RESTORED_DB"))"
  dr_mark NAMES "old=$OLD_DB restored=$RESTORED_DB"
}
s_P1-S01() {
  ask T0_AT "time of the first DB error / bad change, UTC ISO-8601 (Enter = now)" "$(date -u +%FT%TZ)" || return 1
  iso_ok "$T0_AT" || { echo "T0_AT '$T0_AT' is not an ISO-8601 UTC time (e.g. 2026-10-04T09:15:00Z)"; unset T0_AT; save_vars; return 1; }
  dr_mark T0 "first error / bad change" --at "$(date -u -d "$T0_AT" +%FT%T.000Z)"
  dr_mark T1 "incident opened (runner)"
  echo "post [Investigating] in the incident channel (templates/communications)"
}
# S3
s_S3_P1-S02() {
  x "$S/dr-restore.sh" list-snapshots "$PRIMARY_DB" || return 1
  local newest; newest="$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-snapshots --db-instance-identifier "$PRIMARY_DB" \
    --snapshot-type automated --query 'reverse(sort_by(DBSnapshots,&SnapshotCreateTime))[0].DBSnapshotIdentifier' --output text 2>/dev/null)"
  [[ "$newest" == None ]] && newest=""
  ask SNAPSHOT_ID "snapshot to restore" "$newest" || return 1
  local t; t="$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-snapshots --db-snapshot-identifier "$SNAPSHOT_ID" \
    --query 'DBSnapshots[0].[SnapshotCreateTime,Status]' --output text 2>/dev/null)" || { echo "snapshot $SNAPSHOT_ID not found"; unset SNAPSHOT_ID; save_vars; return 1; }
  echo "SNAPSHOT_ID=$SNAPSHOT_ID  created/status: $t  (= the RPO reference)"
  dr_mark SNAPSHOT_CHOSEN "$SNAPSHOT_ID created=${t%%[[:space:]]*}"
}
s_S3_P1-G1()  { gate P1-G1 "restore $SNAPSHOT_ID into $RESTORED_DB — data written after the snapshot time is lost" && dr_mark T2 "GO to restore"; }
s_S3_P2-S00() { x "$S/dr-restore.sh" plan snapshot "$SNAPSHOT_ID" "$RESTORED_DB"; }
s_S3_P2-S01() { x "$S/dr-restore.sh" snapshot "$SNAPSHOT_ID" "$RESTORED_DB"; }
s_S3_P2-S02() { x "$S/dr-eks-rollout.sh" inventory && x "$S/dr-eks-rollout.sh" suspend-cronjobs; }
s_S3_P2-S03() { x "$S/dr-restore.sh" wait "$RESTORED_DB"; }
s_S3_P2-S04() { x "$S/dr-restore.sh" harden "$RESTORED_DB"; }
db_verify() { # app login (fix the password on the NEW instance if needed) + pg_settings + SQL verify + counts
  target || return 1
  export TARGET_DB="$RESTORED_DB"
  if ! x "$S/dr-secret-cutover.sh" precheck; then
    echo "app login failed on $RESTORED_DB (restored DBs keep the password of the snapshot time) → fix-password"
    x "$S/dr-secret-cutover.sh" fix-password && x "$S/dr-secret-cutover.sh" precheck || return 1
  fi
  local rc; x "$S/dr-restore.sh" validate-pg; rc=$?
  (( rc == 3 )) && echo "validate-pg: N/A (no reference: source gone and no pg_settings in the baseline)"
  (( rc == 1 )) && return 1
  [[ "${1:-}" == settings-only ]] && return 0
  echo "\$ psql \"\$TARGET_DSN\" -f automation/sql/20-postfailover-verify.sql"
  dr_run db-post psql "$TARGET_DSN" -X -v ON_ERROR_STOP=1 -f "$ROOT/automation/sql/20-postfailover-verify.sql" || return 1
  if [[ -n "${VERIFY_TABLES:-}" ]]; then dr_run counts "$S/dr-verify.sh" compare-counts; else echo "VERIFY_TABLES empty — no row counts"; fi
}
s_S3_P2-S05() { db_verify; }
s_S3_P3-G0()  { gate P3-G0 "cut the application over to $RESTORED_DB (VALIDATED + verified)"; }
pre_fence() { # main shell: decide whether to fence (it changes the OLD instance)
  local st; st="$(db_status "$OLD_DB")"
  if [[ "$st" != available ]]; then FENCE=skip; echo "OLD_DB $OLD_DB is '$st' → nothing to fence"; return 0; fi
  ask FENCE "OLD_DB $OLD_DB is available — fence it read-only now? readonly | skip (exercise)" readonly
}
fence() {
  [[ "${FENCE:-}" == skip ]] && { echo "fence: skipped (FENCE=skip / old instance $(db_status "$OLD_DB"))"; dr_mark FENCE_SKIPPED "$OLD_DB $(db_status "$OLD_DB")"; return 3; }
  [[ "${FENCE:-}" == readonly ]] || { echo "FENCE must be readonly or skip (got '${FENCE:-}')"; return 1; }
  x "$S/dr-fence-instance.sh" readonly "$OLD_DB"
}
cutover() {
  export TARGET_DB="$RESTORED_DB" CUTOVER_ID="${CUTOVER_ID:-$DR_ID}"
  x "$S/dr-secret-cutover.sh" apply || return 1
  if [[ "$SECRET_MODE" == k8s && -n "${K8S_SECRET_RO:-}" ]]; then
    echo "read-only Secret $K8S_SECRET_RO → $RESTORED_DB as well"
    CUTOVER_SECRET=ro CUTOVER_ID="$CUTOVER_ID-RO" x "$S/dr-secret-cutover.sh" apply || return 1
  fi
  echo "endpoint ledger (failback: dr-secret-cutover.sh failback $CUTOVER_ID):"
  [[ "$SECRET_MODE" == k8s ]] && "$S/dr-secret-cutover.sh" history | tail -5
  return 0
}
after_cutover() {
  x "$S/dr-eks-rollout.sh" resume-cronjobs || return 1
  if ! x "$S/dr-eks-rollout.sh" check; then
    echo "some consumers still run with the old Secret → restart only those"
    x "$S/dr-eks-rollout.sh" restart-stale && x "$S/dr-eks-rollout.sh" check || return 1
  fi
}
s_S3_P3-S01() { fence; }
s_S3_P3-S02() { cutover; }
s_S3_P3-S03() { after_cutover; }
connections() { export TARGET_DB="$RESTORED_DB"; dr_run connections "$S/dr-verify.sh" connections; }
e2e() {
  echo "run the E2E validation playbook: dashboard reachable + ONE successful test transaction"
  ask E2E_REF "test transaction ID / reference (proves the E2E check passed)" "$( (( AUTO )) && echo "auto-local-$(date -u +%H%M%S)")" || return 1
  dr_mark T9 "e2e passed ref=$E2E_REF"
}
declare_restored() { gate "$1" "declare services restored on $RESTORED_DB" || return $?; dr_mark T10 "services restored"; }
s_S3_P4-S01() { connections; }
s_S3_P4-S02() { e2e; }
s_S3_P4-G4()  { declare_restored P4-G4; }
evidence() { x "$S/dr-collect-evidence.sh"; }
s_S3_P5-S01() { evidence; }
# S4
s_S4_P1-S02() { manual P1-S02 "stop the damage: pause the job / migration / data loader (F1 on OLD_DB if the damage is ongoing)" && dr_mark DAMAGE_STOPPED; }
s_S4_P1-S03() {
  x "$S/dr-restore.sh" list-snapshots "$PRIMARY_DB" || return 1
  if [[ -z "${RESTORE_TS:-}" ]]; then
    ask BAD_TS "BAD_TS: time of the bad change, UTC ISO-8601 (RESTORE_TS = BAD_TS − 1 s)" "$( (( AUTO )) && date -u +%FT%TZ)" || return 1
    iso_ok "$BAD_TS" || { echo "BAD_TS '$BAD_TS' is not an ISO-8601 UTC time (e.g. 2026-10-04T09:15:00Z)"; unset BAD_TS; save_vars; return 1; }
    RESTORE_TS="$(date -u -d "$BAD_TS - 1 second" +%FT%TZ)"; export RESTORE_TS; save_vars
  fi
  iso_ok "$RESTORE_TS" || { echo "RESTORE_TS '$RESTORE_TS' is not an ISO-8601 UTC time (e.g. 2026-10-04T09:15:00Z)"; unset RESTORE_TS; save_vars; return 1; }
  local latest; latest="$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-instances --db-instance-identifier "$PRIMARY_DB" \
    --query 'DBInstances[0].LatestRestorableTime' --output text 2>/dev/null)"
  if [[ -n "$latest" && "$latest" != None ]] && (( $(date -u -d "$RESTORE_TS" +%s) > $(date -u -d "$latest" +%s) )); then
    echo "RESTORE_TS $RESTORE_TS is after LatestRestorableTime $latest — not restorable yet"; return 1; fi
  echo "RESTORE_TS=$RESTORE_TS   (latest restorable: ${latest:-n/a})"
  dr_mark RESTORE_TS_CHOSEN "value=$RESTORE_TS bad_ts=${BAD_TS:-n/a}"
}
s_S4_P1-S04() {
  ask RESTORE_MODE "mode: A = restored DB becomes primary · B = repair the data on the primary" A || return 1
  RESTORE_MODE="${RESTORE_MODE^^}"; [[ "$RESTORE_MODE" =~ ^[AB]$ ]] || { echo "mode must be A or B"; unset RESTORE_MODE; save_vars; return 1; }
  save_vars; dr_mark DECISION "mode=$RESTORE_MODE"
}
s_S4_P1-G1()  { gate P1-G1 "restore $PRIMARY_DB to $RESTORE_TS into $RESTORED_DB (mode $RESTORE_MODE) — writes after that time are not in the restored DB" && dr_mark T2 "GO to restore"; }
s_S4_P2-S00() { x "$S/dr-restore.sh" plan pitr "$PRIMARY_DB" "$RESTORED_DB" "$RESTORE_TS"; }
s_S4_P2-S01() { x "$S/dr-restore.sh" pitr "$PRIMARY_DB" "$RESTORED_DB" "$RESTORE_TS"; }
s_S4_P2-S02() { x "$S/dr-restore.sh" wait "$RESTORED_DB" && x "$S/dr-restore.sh" harden "$RESTORED_DB"; }
s_S4_P2-S03() {
  target || return 1
  local out="$DR_EVIDENCE_DIR/db/restore-point-check.txt"
  echo "\$ psql \"\$TARGET_DSN\" -v cutoff=\"'$RESTORE_TS'\" -f automation/sql/05-restore-point-check.sql"
  psql "$TARGET_DSN" -X -At -v cutoff="'$RESTORE_TS'" -f "$ROOT/automation/sql/05-restore-point-check.sql" 2>&1 | tee "$out"
  local rc=${PIPESTATUS[0]}
  (( rc == 0 )) || return 1
  ! grep -q 'FAIL' "$out" || { echo "restore-point check: FAIL lines above — data newer than the restore point"; return 1; }
}
s_S4_P2-G3()   { gate P2-G3 "restore point of $RESTORED_DB signed off by DBA + QA (bad change absent)"; }
s_S4_P3B-S01() { manual P3B-S01 "MODE B: export the affected rows from $RESTORED_DB (pg_dump --data-only -t … / \\copy), apply the reviewed repair script on $PRIMARY_DB in ONE transaction, release F1; delete $RESTORED_DB after 3 days"; }
s_S4_P3A-S01() { x "$S/dr-restore.sh" validate "$RESTORED_DB" || return 1; db_verify settings-only; }
s_S4_P3A-G0()  { gate P3A-G0 "cut the application over to $RESTORED_DB (mode A, VALIDATED)"; }
s_S4_P3A-S02() { fence; }
s_S4_P3A-S03() { x "$S/dr-eks-rollout.sh" inventory && x "$S/dr-eks-rollout.sh" suspend-cronjobs || return 1
                 db_verify settings-only >/dev/null || { echo "app login / settings check failed (see steps log of P3A-S01)"; return 1; }
                 cutover && after_cutover; }
s_S4_P3A-S04() { connections; }
s_S4_P3A-S05() { e2e; }
s_S4_P3A-G5()  { declare_restored P3A-G5; }
s_S4_P4-S01()  { evidence; }
# a step function: s_<SC>_<ID> if it exists, else the common s_<ID>
fn_of() { if declare -F "s_${SC}_$1" >/dev/null; then echo "s_${SC}_$1"; else echo "s_$1"; fi; }
declare -A PRE=([P3-S01]=pre_fence [P3A-S02]=pre_fence)

# ───────────────────── runner ─────────────────────
PASSN=0; FAILN=0; SKIPN=0; STOPPED=""
record() { # id status rc seconds
  STATUS[$1]="$2"; printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$(date -u +%FT%TZ)" >> "$STATEF"
}
show_after() { # id timeline-lines-before marker-file
  local new; new="$(tail -n +"$(( $2 + 1 ))" "$DR_TIMELINE" | jq -r 'select(.marker | test("^RUN_STEP_") | not) | "\(.ts[0:19] | sub("T"; " "))Z  \(.marker)  \(.note)"' 2>/dev/null)"
  [[ -n "$new" ]] && { echo "   🕒 timeline:"; sed 's/^/      /' <<<"$new"; }
  local files; files="$(cd "$RUNDIR" && find . -type f -newer "$3" ! -path './steps/*' ! -name run.log ! -name run-state.tsv \
                         ! -name run-vars.env ! -name timeline.jsonl ! -name commands.jsonl | sed 's|^\./||' | sort)"
  if [[ -n "$files" ]]; then
    echo "   📄 evidence ($(wc -l <<<"$files") new/updated):"
    while read -r f; do printf '      %-60s %8s\n' "$f" "$(du -h "$RUNDIR/$f" | cut -f1)"; done <<<"$files"
  fi
  echo "   📝 step log: steps/$1.log"
}
phase_start() { local var="DR_PHASE_START_${1//[^A-Za-z0-9]/_}"; [[ -n "${!var:-}" ]] && return 0; dr_phase start "$@"; save_vars; }
phase_end()   { local done_var="DR_PHASE_ENDED_${1//[^A-Za-z0-9]/_}"; [[ -n "${!done_var:-}" ]] && return 0
                dr_phase end "$@"; printf -v "$done_var" 1; }
run_fn() { # id fn kind → rc; live output + steps/<id>.log
  local id="$1" fn="$2" kind="$3" log="$RUNDIR/steps/$1.log" rc
  if [[ "$kind" =~ ^(input|gate|manual)$ ]]; then
    # main shell (it sets variables); prompts go straight to the terminal, the output is indented like the others
    "$fn" > >(tee -a "$log" | sed -u 's/^/   │ /') 2>&1; rc=$?; wait $! 2>/dev/null
  elif (( QUIET )); then
    ( [[ "$kind" == change && "$DR_ENV" == prod ]] && export DR_ASSUME_YES=1; "$fn" ) >> "$log" 2>&1; rc=$?
  else
    ( [[ "$kind" == change && "$DR_ENV" == prod ]] && export DR_ASSUME_YES=1; "$fn" ) 2>&1 | tee -a "$log" | sed -u 's/^/   │ /'
    rc=${PIPESTATUS[0]}
  fi
  dr_redact "$log" 2>/dev/null
  return "$rc"
}
step() { # <id>
  local id="$1" kind="${KIND[$1]}" title="${TITLE[$1]}" fn rc t0 el ans d nb mk
  if ! selected "$id"; then echo "⏭  $id $title (not selected)"; SKIPN=$((SKIPN+1)); return 0; fi
  if [[ "${PREV[$id]:-}" =~ ^(PASS|NA)$ && "$ONLY" != *",$id,"* ]]; then
    echo "⏭  $id $title — done earlier (${PREV[$id]})"; STATUS[$id]="${PREV[$id]}"; return 0; fi
  for d in ${NEEDS[$id]:-}; do
    local ds="${STATUS[$d]:-${PREV[$d]:-}}"
    if [[ "$ds" =~ ^(FAIL|BLOCKED)$ ]]; then
      echo "⛔ $id $title — BLOCKED: prerequisite $d $ds"; record "$id" BLOCKED - 0; SKIPN=$((SKIPN+1)); return 0; fi
  done
  if [[ -n "${COND[$id]:-}" ]] && ! "${COND[$id]}"; then
    echo "➖ $id $title — N/A (mode ${RESTORE_MODE:-A})"; record "$id" NA - 0; SKIPN=$((SKIPN+1)); return 0; fi
  fn="$(fn_of "$id")"
  while :; do
    echo; line; printf '▶  %s  %s %s · %s\n   $ %s\n' "$id" "$(icon "$kind")" "$kind" "$title" "${CMD[$id]}"
    [[ -n "${PSTART[$id]:-}" ]] && phase_start ${PSTART[$id]}
    nb="$(wc -l < "$DR_TIMELINE")"; mk="$MARKS/$id"; touch "$mk"
    printf '# %s %s — %s (DR_ID %s)\n' "$(date -u +%FT%TZ)" "$id" "$title" "$DR_ID" > "$RUNDIR/steps/$id.log"
    dr_mark "RUN_STEP_START:$id" "$title" >/dev/null
    t0=$(date +%s); rc=0
    if [[ -n "${PRE[$id]:-}" ]]; then run_fn "$id" "${PRE[$id]}" input || rc=$?; fi
    if (( rc == 0 )) && [[ "$kind" == change && "$DR_ENV" == prod ]]; then dr_confirm "$id $title" || rc=1; fi
    (( rc == 0 )) && { run_fn "$id" "$fn" "$kind"; rc=$?; }
    el=$(( $(date +%s) - t0 ))
    dr_mark "RUN_STEP_END:$id" "rc=$rc elapsed_s=$el" >/dev/null
    case "$rc" in
      0) echo "✅ $id $title  (${el}s)"; record "$id" PASS 0 "$el"; PASSN=$((PASSN+1)) ;;
      3) echo "➖ $id $title — N/A (see output)  (${el}s)"; record "$id" NA 3 "$el"; SKIPN=$((SKIPN+1)) ;;
      4) echo "🛑 $id — answer was not GO: the run stops here (decision recorded)."; record "$id" STOPPED 4 "$el"
         show_after "$id" "$nb" "$mk"; STOPPED="$id"; return 4 ;;
    esac
    if (( rc == 0 || rc == 3 )); then
      show_after "$id" "$nb" "$mk"
      [[ -n "${PEND[$id]:-}" ]] && phase_end ${PEND[$id]}
      return 0
    fi
    echo "❌ $id $title  (rc=$rc, ${el}s) — output above, full log: steps/$id.log"; show_after "$id" "$nb" "$mk"
    case "$ON_FAIL" in
      continue) break ;;
      stop) record "$id" FAIL "$rc" "$el"; FAILN=$((FAILN+1)); STOPPED="$id"; return 1 ;;
      ask) read -r -p "   [r]etry  [s]kip (counts as FAILED: dependent steps are blocked)  [a]bort ? " ans </dev/tty
           case "$ans" in
             r|R) continue ;;
             a|A) record "$id" FAIL "$rc" "$el"; FAILN=$((FAILN+1)); STOPPED="$id"; return 1 ;;
             *) break ;;
           esac ;;
    esac
  done
  record "$id" FAIL "$rc" "$el"; FAILN=$((FAILN+1)); return 0
}

finish() {
  local i st
  {
    printf '# DR run %s — %s — %s\n\nenv %s · runner dr-run.sh · actor %s · git %s\n\n| Step | Kind | Title | Result |\n|---|---|---|---|\n' \
      "$SC" "$DR_ID" "$(date -u +%FT%TZ)" "$DR_ENV" "${DR_ACTOR:-?}" "$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo n/a)"
    for i in "${IDS[@]}"; do st="${STATUS[$i]:-${PREV[$i]:-not run}}"; printf '| %s | %s | %s | %s |\n' "$i" "${KIND[$i]}" "${TITLE[$i]}" "$st"; done
  } > "$REPORT"
  echo; line
  echo "RESULT: PASS=$PASSN FAIL=$FAILN skipped/N/A=$SKIPN${STOPPED:+ · stopped at $STOPPED}"
  for i in "${IDS[@]}"; do st="${STATUS[$i]:-${PREV[$i]:-}}"; [[ -n "$st" ]] && printf '   %-8s %-8s %s\n' "$i" "$st" "${TITLE[$i]}"; done
  if jq -e -s 'any(.marker=="T0")' "$DR_TIMELINE" >/dev/null 2>&1; then echo "phase times:"; dr_summary | sed 's/^/   /'; fi
  echo "evidence: $RUNDIR  (run-report.md · run.log · steps/ · timeline.jsonl)"
  [[ -n "$STOPPED" || $FAILN -gt 0 ]] && echo "resume:   ./automation/scripts/dr-run.sh $SC --resume $DR_ID   (steps that passed are not repeated)"
  dr_mark RUN_END "pass=$PASSN fail=$FAILN skipped=$SKIPN stopped=${STOPPED:-no}" >/dev/null
  dr_sync_evidence
  exec 1>&3 2>&4; wait "$TEE_PID" 2>/dev/null; dr_redact "$RUNLOG"; rm -rf "$MARKS"
}

trap 'echo; echo "interrupted — resume: ./automation/scripts/dr-run.sh $SC --resume $DR_ID"; STOPPED="${STOPPED:-interrupt}"; finish; exit 130' INT TERM
for id in "${IDS[@]}"; do
  step "$id" || break
done
finish
if [[ "$FAILN" -gt 0 ]]; then exit 1; elif [[ -n "$STOPPED" ]]; then exit 4; fi
exit 0
