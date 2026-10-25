#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TEMP="$(mktemp -d)"
TEMP="$(cd "$TEMP" && pwd -P)"
IMAGE="bb3-deployment-mock:test-$$"
CONTAINER="${BB3_DEPLOYMENT_CONTAINER:-bb3-deploument-ec2}"
CONTAINER_ID=''
ROOT="$(cd "$HERE/../../.." && pwd)"
LOG_ROOT="${BB3_DOCKER_TEST_LOG_DIR:-$ROOT/evidence/bb3-deployment-mock}"
LOG_DIR="$LOG_ROOT/$(date -u +%Y%m%dT%H%M%SZ)-$$"
DOCKER=(docker)
if [[ -n "${DOCKER_CONTEXT:-}" ]]; then DOCKER+=(--context "$DOCKER_CONTEXT"); fi
HIGHLIGHT=''; RESET=''
PANEL=false
if [[ -t 1 && -z "${NO_COLOR+x}" && "${TERM:-dumb}" != dumb ]]; then
  HIGHLIGHT=$'\033[1;36m'; RESET=$'\033[0m'
  if [[ -t 0 ]] && (( $(tput lines 2>/dev/null || printf 24) >= 8 )); then PANEL=true; fi
fi
progress() {
  if [[ "$PANEL" == true ]]; then
    printf '\033[1;1H\033[2K%s[%s] %.*s%s\033[3;1H' "$HIGHLIGHT" "$1" \
      "$(( ${COLUMNS:-80} - 10 ))" "$2" "$RESET"
  else
    printf '[%s] %s\n' "$1" "$2"
  fi
}
cleanup() {
  local exit_code=$?
  if [[ "$PANEL" == true ]]; then
    printf '\033[r\033[?1049l'
    if [[ "$exit_code" != 0 ]]; then
      printf '[STOPPED] Docker mock exited %s. Full logs: %s\n' "$exit_code" "$LOG_DIR" >&2
    fi
  fi
  if [[ -n "$CONTAINER_ID" ]]; then "${DOCKER[@]}" rm -f "$CONTAINER_ID" >/dev/null 2>&1 || true; fi
  "${DOCKER[@]}" image rm "$IMAGE" >/dev/null 2>&1 || true
  rm -rf "$TEMP"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
if [[ "$PANEL" == true ]]; then printf '\033[?1049h\033[2J\033[H\033[3;6r\033[3;1H'; fi

mkdir -p "$LOG_DIR"
chmod 700 "$LOG_ROOT" "$LOG_DIR"
BUILD_LOG="$LOG_DIR/docker-build.log"
RUN_LOG="$LOG_DIR/docker-ssh-session.log"

show_build_steps() {
  local line step='' total='' description='' found=false
  local -a recent=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    recent+=("$line")
    if ((${#recent[@]} > 4)); then recent=("${recent[@]:1}"); fi
    if [[ "$line" =~ ^Step[[:space:]]([0-9]+)/([0-9]+)[[:space:]]:[[:space:]](.*)$ ]]; then
      found=true
      step="${BASH_REMATCH[1]}"; total="${BASH_REMATCH[2]}"
      description="${BASH_REMATCH[3]}"
      if [[ "$PANEL" == true ]]; then
        printf '\033[2;1H\033[2K%sBuild %s/%s: %.*s%s\033[3;1H' "$HIGHLIGHT" "$step" "$total" \
          "$(( ${COLUMNS:-80} - 20 ))" "$description" "$RESET"
      fi
    fi
    if [[ "$PANEL" == true ]]; then printf '%s\n' "$line"; fi
  done
  if [[ "$PANEL" == false ]]; then
    if [[ "$found" == true ]]; then printf 'Docker build %s/%s: %s\n' "$step" "$total" "$description"; fi
    printf '%s\n' "${recent[@]}"
  fi
}

show_session_tail() {
  local line
  local -a recent=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    recent+=("$line")
    if ((${#recent[@]} > 4)); then recent=("${recent[@]:1}"); fi
    if [[ "$PANEL" == true ]]; then printf '%s\n' "$line"; fi
  done
  if [[ "$PANEL" == false ]]; then printf '%s\n' "${recent[@]}"; fi
}

progress '1/3' 'Preparing temporary build context and generated SSH key. No sandbox config or host repo is copied.'
mkdir "$TEMP/context"
mkdir -p "$TEMP/context/mock-repo/scripts"
ssh-keygen -q -t ed25519 -N '' -C bb3-docker-ssh-mock -f "$TEMP/client-key"
cp "$TEMP/client-key.pub" "$TEMP/context/mock-authorized_keys"
cp "$TEMP/client-key" "$TEMP/context/mock-client-key"
cp "$HERE/docker-mock/Dockerfile" "$HERE/docker-mock/mock-ssh-config" \
  "$HERE/docker-mock/mock-sshd-config" "$HERE/docker-mock/mock-entrypoint.sh" \
  "$HERE/docker-mock/mock-docker" "$HERE/bb3-deployment.sh" "$HERE/bb3-prompt.sh" "$TEMP/context/"
cp "$HERE/docker-mock/mock-repo/scripts/deploy.sh" "$TEMP/context/mock-repo/scripts/deploy.sh"
[[ "$(find "$TEMP/context" -type f | wc -l | tr -d ' ')" == 10 ]]
printf 'Prepared 10 fixture files and a temporary SSH key; no sandbox configuration or host repository included.\n'

progress '2/3' 'Building the local SSH mock image; live build steps and recent output follow. Full output is retained in docker-build.log.'
if ! "${DOCKER[@]}" build --tag "$IMAGE" "$TEMP/context" 2>&1 | tee "$BUILD_LOG" | show_build_steps; then
  progress 'FAIL' "Docker build failed; full log: $BUILD_LOG"
  tail -n 24 "$BUILD_LOG" >&2
  exit 1
fi
DEPLOY_ENV="${BB3_DEPLOYMENT_ENV:-uat}"
DEPLOY_MODE="${BB3_DEPLOYMENT_MODE:-automatic}"
EXPECTED_EXIT="${BB3_DOCKER_EXPECTED_EXIT:-0}"
GUIDED_ACTIONS="${BB3_DOCKER_TEST_GUIDED_ACTIONS:-}"
[[ "$DEPLOY_ENV" =~ ^(dev|uat|prod)$ && "$DEPLOY_MODE" =~ ^(automatic|guided)$ ]] \
  || { echo 'Docker mock environment/mode is invalid.' >&2; exit 2; }
if [[ "$DEPLOY_MODE" == guided && -n "$GUIDED_ACTIONS" && -z "${BB3_DOCKER_EXPECTED_EXIT:-}" ]]; then EXPECTED_EXIT=130; fi
if [[ "$DEPLOY_MODE" == guided && -z "$GUIDED_ACTIONS" && ! -t 0 ]]; then
  echo 'Guided Docker mock requires an interactive terminal or explicit test responses.' >&2
  exit 2
fi
progress '3/3' "Starting $CONTAINER with no network or host mounts; live SSH output follows. Full output goes to docker-ssh-session.log."
CREATE_ARGS=(--name "$CONTAINER" --network none --read-only --cap-drop ALL \
  --cap-add SETUID --cap-add SETGID --cap-add SYS_CHROOT \
  --security-opt no-new-privileges --pids-limit 48 \
  --tmpfs '/tmp:rw,nosuid,nodev,noexec,size=16m' \
  --tmpfs '/home/mock/projects:rw,nosuid,nodev,exec,size=16m,uid=2000,gid=2000,mode=755' \
  --env ENV="$DEPLOY_ENV" --env BB3_DEPLOYMENT_CONTAINER="$CONTAINER" \
  --env BB3_DEPLOYMENT_HOST=uat-1.app.beepte.ch --env BB3_DOCKER_STACK_NAME=beepbeep \
  --env BB3_DEPLOYMENT_MODE="$DEPLOY_MODE" \
  --env BB3_DEPLOY_WAIT_SECONDS=30)
if [[ "$DEPLOY_MODE" == guided && -n "$GUIDED_ACTIONS" ]]; then
  CREATE_ARGS+=(--env "BB3_DOCKER_GUIDED_ACTIONS=$GUIDED_ACTIONS")
elif [[ "$DEPLOY_MODE" == guided ]]; then
  CREATE_ARGS+=(--interactive --tty)
fi
CONTAINER_ID="$("${DOCKER[@]}" create "${CREATE_ARGS[@]}" "$IMAGE")"
RUN_EXIT=0
if [[ "$DEPLOY_MODE" == guided && -n "$GUIDED_ACTIONS" ]]; then
  if "${DOCKER[@]}" start --attach "$CONTAINER_ID" 2>&1 | tee "$RUN_LOG" | show_session_tail; then RUN_EXIT=0; else RUN_EXIT=$?; fi
elif [[ "$DEPLOY_MODE" == guided ]]; then
  progress 'GUIDED INPUT' 'Attached directly to Docker TTY; Enter/n/s keys go to the guided prompts.'
  if "${DOCKER[@]}" start --attach --interactive "$CONTAINER_ID"; then RUN_EXIT=0; else RUN_EXIT=$?; fi
  "${DOCKER[@]}" logs "$CONTAINER_ID" > "$RUN_LOG" 2>&1
elif "${DOCKER[@]}" start --attach "$CONTAINER_ID" 2>&1 | tee "$RUN_LOG" | show_session_tail; then
  RUN_EXIT=0
else
  RUN_EXIT=$?
fi
if [[ "$RUN_EXIT" != "$EXPECTED_EXIT" ]]; then
  if [[ "$DEPLOY_MODE" == guided && -z "$GUIDED_ACTIONS" && "$RUN_EXIT" == 130 ]]; then
    progress 'STOPPED' 'Guided mock cancelled; no deployment attestation may be recorded.'
    exit 130
  fi
  progress 'FAIL' "Mock SSH run failed; full log: $RUN_LOG"
  tail -n 24 "$RUN_LOG" >&2
  exit 1
fi
[[ "$("${DOCKER[@]}" inspect --format '{{.State.ExitCode}}' "$CONTAINER_ID")" == "$RUN_EXIT" ]] || {
  progress 'FAIL' "Mock process returned nonzero; full log: $RUN_LOG"
  tail -n 24 "$RUN_LOG" >&2
  exit 1
}

expected_output=(
  'MOCK SSH MODE: authenticating over OpenSSH to the isolated Docker host' \
  'MOCK_CONTAINER_NAME=bb3-deploument-ec2' \
  'branch=main' \
  'Already up to date.' \
  'MOCK REMOTE DEPLOY: scripts/deploy.sh uat completed'
)
if [[ "$DEPLOY_MODE" == automatic ]]; then
  expected_output+=(
    'All desired tasks are Running and service replicas match.'
    'beepbeep_web     replicated   2/2'
    'warning: mock warning line'
    'automatic deployment sequence finished.'
  )
elif [[ -n "$GUIDED_ACTIONS" ]]; then
  expected_output+=(
    '[MOCK INPUT] response=run'
    'All desired tasks are Running and service replicas match.'
    '[MOCK INPUT] response=skip'
    'Skipped SERVICES.'
    '[MOCK INPUT] response=stop'
    'Stopped before TASKS'
  )
  [[ "$(grep -Fc '[MOCK INPUT] response=run' "$RUN_LOG")" == 3 ]]
  ! grep -F 'docker service logs' "$RUN_LOG" >/dev/null || {
    echo 'FAIL guided n did not stop subsequent log checks' >&2; exit 1;
  }
else
  expected_output+=(
    '[PULL] Pull approved main updates'
    '[DEPLOY] Run uat deployment script'
    '[VERIFY] Wait for all desired tasks and replicas to converge'
    'All desired tasks are Running and service replicas match.'
    'guided deployment sequence finished.'
  )
fi
for expected in "${expected_output[@]}"; do
  grep -F "$expected" "$RUN_LOG" >/dev/null
done
if [[ -n "${BB3_DEPLOY_TRANSCRIPT:-}" ]]; then
  [[ -f "$BB3_DEPLOY_TRANSCRIPT" && ! -L "$BB3_DEPLOY_TRANSCRIPT" && -O "$BB3_DEPLOY_TRANSCRIPT" ]] \
    || { echo 'Mock transcript destination must be an existing owned regular file.' >&2; exit 2; }
  printf '\nDOCKER MOCK TRANSCRIPT: SIMULATION ONLY, NOT ACTUAL DEPLOYMENT EVIDENCE\n' >> "$BB3_DEPLOY_TRANSCRIPT"
  cat "$RUN_LOG" >> "$BB3_DEPLOY_TRANSCRIPT"
fi
if grep -E '(^|[[:space:]])(ssh|docker|git|watch): command not found' "$RUN_LOG" >/dev/null; then
  echo 'FAIL mock image unexpectedly attempted a real remote utility' >&2
  exit 1
fi
"${DOCKER[@]}" rm "$CONTAINER_ID" >/dev/null
CONTAINER_ID=''
if [[ "$PANEL" == true ]]; then
  printf '\033[r\033[?1049l'
  PANEL=false
fi
progress 'PASS' 'The real OpenSSH client/server completed the simulated deployment sequence inside the no-network mock host.'
printf 'Full build log: %s\nFull SSH session log: %s\n' "$BUILD_LOG" "$RUN_LOG"

if [[ "${BB3_DOCKER_TEST_GUIDED:-0}" == 1 ]]; then
  progress 'GUIDED TEST' 'Second SSH session: Enter runs required steps, s skips optional SERVICES, n stops before TASKS.'
  BB3_DEPLOYMENT_MODE=guided \
    BB3_DOCKER_TEST_GUIDED=0 \
    BB3_DOCKER_TEST_TTY=0 \
    BB3_DOCKER_EXPECTED_EXIT=130 \
    BB3_DOCKER_TEST_GUIDED_ACTIONS=run,run,run,skip,stop \
    bash "$HERE/test-bb3-deployment-docker.sh"
fi

if [[ "${BB3_DOCKER_TEST_TTY:-0}" == 1 ]]; then
  progress 'TTY TEST' 'Testing interactive guided completion and cancellation through a real host TTY.'
  BB3_DOCKER_TEST_SCRIPT="$HERE/test-bb3-deployment-docker.sh" expect <<'EXPECT'
set timeout 180
match_max -d 200000
log_user 0
set env(TERM) xterm
unset -nocomplain env(NO_COLOR)
unset -nocomplain env(BB3_DOCKER_TEST_GUIDED_ACTIONS) env(BB3_DOCKER_EXPECTED_EXIT)
set env(BB3_DEPLOYMENT_MODE) guided
set env(BB3_DOCKER_TEST_GUIDED) 0
set env(BB3_DOCKER_TEST_TTY) 0
foreach scenario {complete cancel} {
  set transcript ""
  spawn -noecho bash $env(BB3_DOCKER_TEST_SCRIPT)
  if {$scenario eq "complete"} {
    foreach key {PULL DEPLOY VERIFY SERVICES TASKS LOGS WARNINGS} {
      expect {
        -re [format {\[%s\][^\r\n]*skip\]: } $key] {append transcript $expect_out(buffer); send -- "\r"}
        timeout {puts stderr "FAIL TTY timed out waiting for $key"; exit 1}
        eof {puts stderr "FAIL TTY exited before $key: $expect_out(buffer)"; exit 1}
      }
    }
    set expected 0
    set marker {\[PASS\]}
  } else {
    expect {
      -re {\[PULL\][^\r\n]*skip\]: } {append transcript $expect_out(buffer); send -- "n\r"}
      timeout {puts stderr "FAIL TTY timed out waiting to cancel PULL"; exit 1}
      eof {puts stderr "FAIL TTY exited before cancellation: $expect_out(buffer)"; exit 1}
    }
    set expected 130
    set marker {\[STOPPED\]}
  }
  expect {
    -re $marker {append transcript $expect_out(buffer)}
    timeout {puts stderr "FAIL TTY $scenario did not finish"; exit 1}
    eof {puts stderr "FAIL TTY $scenario missing result: $expect_out(buffer)"; exit 1}
  }
  expect {
    eof {append transcript $expect_out(buffer)}
    timeout {puts stderr "FAIL TTY $scenario did not exit"; exit 1}
  }
  set result [wait]
  if {[lindex $result 3] != $expected} {
    puts stderr "FAIL TTY $scenario returned $result; expected $expected"
    exit 1
  }
  foreach control [list "\033\[?1049h" "\033\[3;6r" "\033\[?1049l"] {
    if {[string first $control $transcript] < 0} {
      puts stderr "FAIL TTY $scenario did not preserve the compact pane lifecycle"
      exit 1
    }
  }
  puts "PASS interactive guided $scenario (exit $expected)"
}
EXPECT
fi