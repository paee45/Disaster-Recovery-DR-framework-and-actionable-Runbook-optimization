#!/usr/bin/env bash
set -o pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  echo 'Bash 4+ required; on macOS use /opt/homebrew/bin/bash.' >&2
  exit 2
fi
command -v jq >/dev/null || { echo 'jq required (no dependencies installed).' >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
S="$ROOT/automation/scripts"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dr-stop-tests.XXXXXX")" || exit 2
trap 'rm -rf "$TMP"' EXIT
PASSN=0; FAILN=0

FENCE_CODE="$(sed -n '/^local_stopped() {/,/^if \[\[ "\$CMD" != wait-stopped/{ /^if \[\[ "\$CMD" != wait-stopped/d; p; }' "$S/dr-fence-instance.sh")"
RUNNER_CODE="$(sed -n '/^pre_fence() {/,/^evidence() /p' "$S/dr-run.sh")"
S4_CODE="$(sed -n '/^s_S4_P3A-S02() /,/^# a step/{ /^# a step/d; p; }' "$S/dr-run.sh")"
CATALOGUE="$(sed -n '/^RESTORE_SUFFIX=/,/^IDS=/{ /^IDS=/d; p; }' "$S/dr-run.sh")"
STEP_CODE="$(sed -n '/^step() {/,/^}/p' "$S/dr-run.sh")"
for section in FENCE_CODE RUNNER_CODE S4_CODE CATALOGUE STEP_CODE; do
  [[ -n "${!section}" ]] || { echo "Missing source section: $section" >&2; exit 2; }
done
eval "$FENCE_CODE" || exit 2
eval "$RUNNER_CODE" || exit 2
eval "$S4_CODE" || exit 2
eval "$STEP_CODE" || exit 2
FAILBACK_POLICY="$(sed -n '/^failback_data_policy() {/,/^}/p' "$ROOT/iac/local/dr.sh")"
eval "$FAILBACK_POLICY" || exit 2

trace() { printf '%s\n' "$*" >> "$CALLS"; }
aws() {
  [[ "$1" == --profile && "$2" == "$AWS_PROFILE" && "$3" == --region && "$4" == "$AWS_REGION" ]] || return 97
  shift 4
  case "$*" in
    'rds describe-db-instances --db-instance-identifier offline-old --query DBInstances[0] --output json')
      trace describe
      (( DESCRIBE_RC == 0 )) || return "$DESCRIBE_RC"
      printf '%s\n' "$INSTANCE" ;;
    'rds stop-db-instance --db-instance-identifier offline-old --output json')
      trace stop
      (( STOP_RC == 0 )) || return "$STOP_RC"
      printf '%s\n' '{"DBInstance":{"DBInstanceStatus":"stopping"}}' ;;
    'rds wait db-instance-stopped --db-instance-identifier offline-old')
      trace wait
      return "$WAIT_RC" ;;
    *) trace "UNEXPECTED aws $*"; return 98 ;;
  esac
}
dr_guard() { return 0; }
dr_confirm() { return 0; }
dr_mark() { trace "mark $1"; }
dr_mark_once() {
  if ! grep -Fx "mark $1" "$CALLS" >/dev/null; then dr_mark "$@"; fi
}
master_psql() { trace 'UNEXPECTED master_psql'; return 98; }
x() {
  case "$1 ${2:-}" in
    "$S/dr-fence-instance.sh stop") trace fence; stop_instance ;;
    "$S/dr-fence-instance.sh wait-stopped") wait_stopped ;;
    "$S/dr-secret-cutover.sh apply") trace cutover ;;
    "$S/dr-eks-rollout.sh resume-cronjobs") trace after_cutover ;;
    "$S/dr-eks-rollout.sh check") trace stale_check ;;
    *) trace "UNEXPECTED x $*"; return 98 ;;
  esac
}
dr_run() {
  [[ "$*" == "connections $S/dr-verify.sh connections" ]] || return 98
  trace connections
  return "$VERIFY_RC"
}
ask() { trace "ask $1"; printf -v "$1" '%s' offline-reference; }
save_vars() { return 0; }
db_status() { printf '%s\n' "$OLD_STATUS"; return "$STATUS_RC"; }
mode_a() { return 0; }
selected() { return 0; }
fn_of() { printf 's_%s_%s\n' "$SC" "$1"; }
run_fn() { "$2"; }
record() { STATUS[$1]="$2"; }
line() { return 0; }
icon() { return 0; }
show_after() { return 0; }
phase_start() { return 0; }
phase_end() { return 0; }

expect_trace() {
  local actual
  actual="$(cat "$CALLS")"
  [[ "$actual" == "$1" ]] || { printf 'Expected:\n%s\nActual:\n%s\n' "$1" "$actual"; return 1; }
}
reject() {
  local result=0
  "$@" || result=$?
  (( result != 0 )) || { echo "Unexpected success: $*"; return 1; }
}
no_marker() { ! grep -Fx "mark $1" "$CALLS" >/dev/null; }
set_instance() { INSTANCE="$(jq -c "$1" <<< "$INSTANCE")"; }

t() {
  local name="$1"; shift
  local test_dir="$TMP/$((PASSN + FAILN + 1))"
  mkdir -p "$test_dir/db" || exit 2
  if (
    CALLS="$test_dir/calls"; : > "$CALLS"
    DR_EVIDENCE_DIR="$test_dir"; STATE="$test_dir/db/fence-offline-old"
    DR_ENV=uat; DB=offline-old; OLD_DB="$DB"; RESTORED_DB=offline-restored
    AWS_PROFILE=offline-stub; AWS_REGION=ap-southeast-1
    INSTANCE='{"Engine":"postgres","DBInstanceStatus":"available","ReadReplicaDBInstanceIdentifiers":[]}'
    DESCRIBE_RC=0; STOP_RC=0; WAIT_RC=0; VERIFY_RC=0
    OLD_STATUS=available; STATUS_RC=0; FENCE=stop
    DR_ID=offline-test; SECRET_MODE=eso; AUTO=0; E2E_REF=offline-reference
    "$@"
  ) > "$test_dir/output" 2>&1; then
    PASSN=$((PASSN + 1)); printf 'PASS %s\n' "$name"
  else
    FAILN=$((FAILN + 1)); printf 'FAIL %s\n' "$name"
    sed 's/^/  /' "$test_dir/output"
  fi
}

request_only() {
  stop_instance || return 1
  expect_trace $'describe\nstop\nmark STOP_REQUESTED' &&
    [[ -s "${STATE}.before-stop.json" && -s "${STATE}.stop-requested.json" && ! -e "${STATE}.stopped.json" ]]
}
reject_shape() {
  set_instance "$1" || return 1
  reject stop_instance && expect_trace describe
}
reject_state() {
  set_instance ".DBInstanceStatus = \"$1\"" || return 1
  reject stop_instance && expect_trace describe
}
request_failure() {
  STOP_RC=42
  reject stop_instance && expect_trace $'describe\nstop' && no_marker FENCE && no_marker STOP_REQUESTED
}
describe_failure() {
  DESCRIBE_RC=42
  reject "$1" && expect_trace "$2" && no_marker FENCE
}
idempotent_request() {
  set_instance ".DBInstanceStatus = \"$1\"" || return 1
  stop_instance && stop_instance && expect_trace $'describe\ndescribe' &&
    [[ ! -e "${STATE}.stop-requested.json" ]]
}
local_reject() {
  DR_ENV=local
  reject "$1" && expect_trace ''
}
local_fixture() {
  DR_ENV=local; DB=app-pg-local
  HERE="$test_dir/automation/scripts"
  mkdir -p "$HERE" "$test_dir/tests/local/.state"
  printf '%s\n' '{"container":"/drtest-pg-old","state":{"Running":false,"Status":"exited"}}' \
    > "$test_dir/tests/local/.state/local-db-old.json"
  dr_endpoint() { echo '172.30.0.21 5432'; }
  pg_isready() { return "$PROBE_RC"; }
  PROBE_RC="$1"
  if [[ "$PROBE_RC" == 2 ]]; then
    stop_instance && wait_stopped && [[ -s "${STATE}.stopped.json" ]] \
      && expect_trace $'mark LOCAL_STOP_CONFIRMED\nmark FENCE'
  else
    reject stop_instance && expect_trace ''
  fi
}
wait_timeout() {
  WAIT_RC=255
  reject wait_stopped && expect_trace wait && [[ ! -e "${STATE}.stopped.json" ]]
}
wait_contradiction() {
  set_instance ".DBInstanceStatus = \"$1\"" || return 1
  reject wait_stopped && expect_trace $'wait\ndescribe' && [[ ! -e "${STATE}.stopped.json" ]]
}
confirmed_stop() {
  stop_instance || return 1
  no_marker FENCE || return 1
  set_instance '.DBInstanceStatus = "stopped"' || return 1
  wait_stopped && wait_stopped &&
    expect_trace $'describe\nstop\nmark STOP_REQUESTED\nwait\ndescribe\nmark FENCE\nwait\ndescribe' &&
    jq -e '.DBInstanceStatus == "stopped"' "${STATE}.stopped.json" >/dev/null
}
reject_restore() {
  printf '{}\n' > "${STATE}.$1"
  printf '[]\n' > "${STATE}.sgs.json"
  : > "${STATE}.readonly"
  reject restore && expect_trace ''
}
pre_fence_status() {
  OLD_STATUS="$1"; FENCE='readonly'
  pre_fence && [[ "$FENCE" == stop ]] && expect_trace ''
}
pre_fence_reject() {
  OLD_STATUS="$1"
  reject pre_fence && expect_trace ''
}
e2e_wait_failure() {
  WAIT_RC=255
  reject e2e && expect_trace wait && no_marker T9
}

runner_case() {
  local SC="$1" failure="$2" step_id fence_step connections_step e2e_step
  local ONLY='' ON_FAIL=continue QUIET=1 STOPPED='' SKIPN=0 FAILN=0 PASSN=0
  local RUNDIR="$test_dir" MARKS="$test_dir/marks" DR_TIMELINE="$test_dir/timeline"
  local -A STATUS=() PREV=() KIND=() TITLE=() CMD=() PRE=()
  eval "$CATALOGUE" || return 1
  for step_id in "${STEPS[@]}"; do
    local identifier kind title command
    IFS='|' read -r identifier kind title command <<< "$step_id"
    KIND[$identifier]="$kind"; TITLE[$identifier]="$title"; CMD[$identifier]="$command"
  done
  mkdir -p "$RUNDIR/steps" "$MARKS" || return 1
  : > "$DR_TIMELINE"
  if [[ "$SC" == S3 ]]; then
    fence_step=P3-S01; connections_step=P4-S01; e2e_step=P4-S02
    local cutover_steps=(P3-S02 P3-S03)
  else
    fence_step=P3A-S02; connections_step=P3A-S04; e2e_step=P3A-S05
    local cutover_steps=(P3A-S03)
  fi
  step "$fence_step" || return 1
  for step_id in "${cutover_steps[@]}"; do step "$step_id" || return 1; done
  local actions
  actions="$(sed -n '/^fence$/p; /^cutover$/p; /^after_cutover$/p; /^wait$/p; /^connections$/p' "$CALLS")"
  [[ "$actions" == $'fence\ncutover\nafter_cutover' ]] || return 1
  no_marker FENCE || return 1
  set_instance '.DBInstanceStatus = "stopped"' || return 1
  case "$failure" in wait) WAIT_RC=255 ;; verify) VERIFY_RC=42 ;; esac
  step "$connections_step" || return 1
  step "$e2e_step" || return 1
  if [[ "$failure" != none ]]; then
    [[ "${STATUS[$connections_step]}" == FAIL && "${STATUS[$e2e_step]}" == BLOCKED ]] &&
      no_marker T9 && ! grep -Fx 'ask E2E_REF' "$CALLS" >/dev/null
  else
    [[ "${STATUS[$connections_step]}" == PASS && "${STATUS[$e2e_step]}" == PASS ]] || return 1
    actions="$(sed -n '/^fence$/p; /^cutover$/p; /^after_cutover$/p; /^wait$/p; /^connections$/p; /^mark FENCE$/p; /^mark T9$/p' "$CALLS")"
    [[ "$actions" == $'fence\ncutover\nafter_cutover\nwait\nmark FENCE\nconnections\nwait\nmark T9' ]]
  fi
}

lifecycle_case() {
  local variant="$1" stub_dir="$test_dir/lifecycle-bin"
  local lifecycle_host=unix:///offline/docker.sock lifecycle_name=drtest-pg-old
  local lifecycle_id=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
  local want_running=false reported_running=false reported_name=/drtest-pg-old
  local name_rc=0 action_rc=0 state_rc=0 expected_rc=0 actual_rc=0
  local expected_calls inspect_name action_call inspect_state actual_calls
  mkdir -p "$stub_dir" || return 1
  cat > "$stub_dir/docker" <<'DOCKER_STUB'
#!/opt/homebrew/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$LIFECYCLE_CALLS"
[[ "$#" -ge 2 && "$1" == --host && "$2" == "$LIFECYCLE_HOST" ]] || exit 98
if [[ "$#" == 6 && "$3" == inspect && "$4" == "$LIFECYCLE_ID" && "$5" == --format ]]; then
  case "$6" in
    '{{.Name}}')
      (( LIFECYCLE_NAME_RC == 0 )) || exit "$LIFECYCLE_NAME_RC"
      printf '%s\n' "$LIFECYCLE_REPORTED_NAME" ;;
    '{{.State.Running}}')
      (( LIFECYCLE_STATE_RC == 0 )) || exit "$LIFECYCLE_STATE_RC"
      printf '%s\n' "$LIFECYCLE_REPORTED_RUNNING" ;;
    *) exit 98 ;;
  esac
elif [[ "$#" == 5 && "$3" == container && ( "$4" == stop || "$4" == start ) \
  && "$5" == "$LIFECYCLE_ID" ]]; then
  (( LIFECYCLE_ACTION_RC == 0 )) || exit "$LIFECYCLE_ACTION_RC"
else
  exit 98
fi
DOCKER_STUB
  chmod +x "$stub_dir/docker" || return 1
  case "$variant" in
    start|start-failure|start-contradiction|restored-start)
      want_running=true; reported_running=true ;;
  esac
  case "$variant" in
    invalid-socket) lifecycle_host=tcp://offline.invalid:2375; expected_rc=2 ;;
    invalid-name) lifecycle_name=unrelated-postgres; expected_rc=2 ;;
    invalid-running) want_running=yes; expected_rc=2 ;;
    missing-id) lifecycle_id=''; expected_rc=1 ;;
    name-mismatch) reported_name=/drtest-pg-replica; expected_rc=2 ;;
    name-inspect-failure) name_rc=41; expected_rc=41 ;;
    stop-failure|start-failure) action_rc=42; expected_rc=42 ;;
    state-inspect-failure) state_rc=43; expected_rc=43 ;;
    stop-contradiction) reported_running=true; expected_rc=1 ;;
    start-contradiction) reported_running=false; expected_rc=1 ;;
    malformed-running) reported_running=unknown; expected_rc=1 ;;
    replica-stop) lifecycle_name=drtest-pg-replica; reported_name=/drtest-pg-replica ;;
    restored-start) lifecycle_name=drtest-pg-restored; reported_name=/drtest-pg-restored ;;
    missing-stub) rm "$stub_dir/docker" || return 1; expected_rc=127 ;;
    stop|start) ;;
    *) return 1 ;;
  esac
  inspect_name="--host $lifecycle_host inspect $lifecycle_id --format {{.Name}}"
  action_call="--host $lifecycle_host container stop $lifecycle_id"
  [[ "$want_running" != true ]] || action_call="--host $lifecycle_host container start $lifecycle_id"
  inspect_state="--host $lifecycle_host inspect $lifecycle_id --format {{.State.Running}}"
  expected_calls="$inspect_name"$'\n'"$action_call"$'\n'"$inspect_state"
  case "$variant" in
    invalid-socket|invalid-name|invalid-running|missing-id|missing-stub) expected_calls='' ;;
    name-mismatch|name-inspect-failure) expected_calls="$inspect_name" ;;
    stop-failure|start-failure) expected_calls="$inspect_name"$'\n'"$action_call" ;;
  esac
  : > "$test_dir/lifecycle-calls"
  PATH="$stub_dir" BASH_ENV=/dev/null ENV=/dev/null \
    DOCKER_HOST="$lifecycle_host" CONTAINER_ID="$lifecycle_id" \
    CONTAINER_NAME="$lifecycle_name" WANT_RUNNING="$want_running" \
    LIFECYCLE_CALLS="$test_dir/lifecycle-calls" LIFECYCLE_HOST="$lifecycle_host" \
    LIFECYCLE_ID="$lifecycle_id" LIFECYCLE_REPORTED_NAME="$reported_name" \
    LIFECYCLE_REPORTED_RUNNING="$reported_running" LIFECYCLE_NAME_RC="$name_rc" \
    LIFECYCLE_ACTION_RC="$action_rc" LIFECYCLE_STATE_RC="$state_rc" \
    "$BASH" --noprofile --norc "$ROOT/iac/local/platform/postgres-lifecycle.sh" \
    > "$test_dir/lifecycle-output" 2>&1 || actual_rc=$?
  [[ "$actual_rc" == "$expected_rc" ]] || {
    printf 'Expected lifecycle exit %s, got %s:\n%s\n' "$expected_rc" "$actual_rc" "$(< "$test_dir/lifecycle-output")"
    return 1
  }
  actual_calls="$(< "$test_dir/lifecycle-calls")"
  [[ "$actual_calls" == "$expected_calls" ]] || {
    printf 'Expected lifecycle calls:\n%s\nActual:\n%s\n' "$expected_calls" "$actual_calls"
    return 1
  }
  if (( expected_rc == 0 )); then
    [[ "$(< "$test_dir/lifecycle-output")" == "Verified $lifecycle_name running=$want_running (existing container, volume retained)." ]]
  else
    ! grep -F 'Verified ' "$test_dir/lifecycle-output" >/dev/null
  fi
}

policy_case() {
  local environment="$1" confirmation="$2" expected="$3" observed
  DR_ENV="$environment"
  if [[ "$expected" == reject ]]; then
    reject failback_data_policy "$confirmation"
  else
    observed="$(failback_data_policy "$confirmation")" && [[ "$observed" == "$expected" ]]
  fi
}

t 'local failback waiver records data-loss acceptance, not reconciliation' policy_case local ACCEPT_LOCAL_DATA_LOSS local-test-data-loss-accepted
t 'local failback reconciliation remains available' policy_case local RECONCILED reconciled
for environment in dev uat prod ''; do
  t "failback waiver refused outside local: ${environment:-unset}" policy_case "$environment" ACCEPT_LOCAL_DATA_LOSS reject
done
t 'local failback empty data confirmation cancels' policy_case local '' reject
t 'stop requests asynchronously without waiter or FENCE' request_only
t 'read replica rejected' reject_shape '.ReadReplicaSourceDBInstanceIdentifier = "offline-source"'
t 'source with replicas rejected' reject_shape '.ReadReplicaDBInstanceIdentifiers = ["offline-replica"]'
t 'cluster member rejected' reject_shape '.DBClusterIdentifier = "offline-cluster"'
t 'non-PostgreSQL rejected' reject_shape '.Engine = "mysql"'
t 'missing engine rejected' reject_shape 'del(.Engine)'
for db_state in creating modifying failed deleting unknown; do
  t "stop rejects state $db_state" reject_state "$db_state"
done
t 'stop describe API failure rejected' describe_failure stop_instance describe
t 'stop API failure emits neither request nor FENCE marker' request_failure
for db_state in stopping stopped; do
  t "stop is idempotent when $db_state, without claiming isolation" idempotent_request "$db_state"
  t "runner adopts $db_state as stop requiring confirmation" pre_fence_status "$db_state"
done
t 'local stop rejected before AWS' local_reject stop_instance
t 'local wait rejected before AWS' local_reject wait_stopped
t 'local physical stopped receipt and no-response probe accepted' local_fixture 2
for probe_code in 0 1 3 127; do
  t "local physical stop rejects reachable or invalid probe $probe_code" local_fixture "$probe_code"
done
t 'wait timeout emits no FENCE' wait_timeout
t 'wait describe API failure rejected' describe_failure wait_stopped $'wait\ndescribe'
for db_state in available stopping; do
  t "wait rejects contradictory describe: $db_state" wait_contradiction "$db_state"
done
t 'confirmed stop records FENCE only after wait and describe' confirmed_stop
t 'restore refuses stop-requested F3 evidence before F1/F2 undo' reject_restore stop-requested.json
t 'restore refuses stopped F3 evidence before F1/F2 undo' reject_restore stopped.json
for db_state in failed unknown; do
  t "runner rejects unproven isolation: $db_state" pre_fence_reject "$db_state"
done
t 'direct E2E wait failure never asks for reference or emits T9' e2e_wait_failure
for scenario in S3 S4; do
  t "$scenario actual steps preserve fence/cutover/after_cutover/connections order" runner_case "$scenario" none
  t "$scenario actual NEEDS blocks E2E after wait failure" runner_case "$scenario" wait
  t "$scenario actual NEEDS blocks E2E after connection verification failure" runner_case "$scenario" verify
done
for lifecycle_variant in stop start replica-stop restored-start invalid-socket invalid-name invalid-running \
  missing-id name-mismatch name-inspect-failure stop-failure start-failure state-inspect-failure \
  stop-contradiction start-contradiction malformed-running missing-stub; do
  t "offline container lifecycle: $lifecycle_variant (existing ID, no volume removal or recreate)" \
    lifecycle_case "$lifecycle_variant"
done
printf '\nTests: %s; passed: %s; failed: %s\n' "$((PASSN + FAILN))" "$PASSN" "$FAILN"
(( FAILN == 0 ))