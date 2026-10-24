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
if [[ -t 1 && -z "${NO_COLOR+x}" && "${TERM:-dumb}" != dumb ]]; then
  HIGHLIGHT=$'\033[1;36m'; RESET=$'\033[0m'
fi
progress() { printf '%s[%s] %s%s\n' "$HIGHLIGHT" "$1" "$2" "$RESET"; }
cleanup() {
  if [[ -n "$CONTAINER_ID" ]]; then "${DOCKER[@]}" rm -f "$CONTAINER_ID" >/dev/null 2>&1 || true; fi
  "${DOCKER[@]}" image rm "$IMAGE" >/dev/null 2>&1 || true
  rm -rf "$TEMP"
}
trap cleanup EXIT

mkdir -p "$LOG_DIR"
chmod 700 "$LOG_ROOT" "$LOG_DIR"
BUILD_LOG="$LOG_DIR/docker-build.log"
RUN_LOG="$LOG_DIR/docker-ssh-session.log"

show_build_steps() {
  local line step='' total='' description='' index start found=false
  local -a recent=()
  emit_step() {
    [[ -n "$step" ]] || return 0
    printf '%sDocker build %s/%s: %s%s\n' "$HIGHLIGHT" "$step" "$total" "$description" "$RESET"
    start=0
    ((${#recent[@]} > 3)) && start=$((${#recent[@]} - 3))
    for ((index=start; index<${#recent[@]}; index++)); do printf '  %s\n' "${recent[$index]}"; done
  }
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^Step[[:space:]]([0-9]+)/([0-9]+)[[:space:]]:[[:space:]](.*)$ ]]; then
      found=true
      emit_step
      step="${BASH_REMATCH[1]}"; total="${BASH_REMATCH[2]}"
      description="${BASH_REMATCH[3]}"; recent=()
    elif [[ -n "$step" ]]; then
      recent+=("$line")
    fi
  done < "$BUILD_LOG"
  emit_step
  if [[ "$found" == false ]]; then
    progress 'BUILD LOG' 'This Docker engine uses a different progress format; showing the final 8 lines.'
    tail -n 8 "$BUILD_LOG"
  fi
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

progress '2/3' 'Building the local SSH mock image; full output is retained in docker-build.log.'
if ! "${DOCKER[@]}" build --tag "$IMAGE" "$TEMP/context" > "$BUILD_LOG" 2>&1; then
  progress 'FAIL' "Docker build failed; full log: $BUILD_LOG"
  tail -n 24 "$BUILD_LOG" >&2
  exit 1
fi
show_build_steps
DEPLOY_ENV="${BB3_DEPLOYMENT_ENV:-uat}"
DEPLOY_MODE="${BB3_DEPLOYMENT_MODE:-automatic}"
[[ "$DEPLOY_ENV" =~ ^(dev|uat|prod)$ && "$DEPLOY_MODE" =~ ^(automatic|guided)$ ]] \
  || { echo 'Docker mock environment/mode is invalid.' >&2; exit 2; }
progress '3/3' "Starting $CONTAINER with no network or host mounts; full SSH output goes to docker-ssh-session.log."
CONTAINER_ID="$("${DOCKER[@]}" create --name "$CONTAINER" --network none --read-only --cap-drop ALL \
  --cap-add SETUID --cap-add SETGID --cap-add SYS_CHROOT \
  --security-opt no-new-privileges --pids-limit 48 --interactive --tty \
  --tmpfs /tmp:rw,nosuid,nodev,noexec,size=16m \
  --tmpfs /home/mock/projects:rw,nosuid,nodev,exec,size=16m,uid=2000,gid=2000,mode=755 \
  --env ENV="$DEPLOY_ENV" --env BB3_DEPLOYMENT_CONTAINER="$CONTAINER" \
  --env BB3_DEPLOYMENT_HOST=uat-1.app.beepte.ch --env BB3_DOCKER_STACK_NAME=beepbeep \
  --env BB3_DEPLOYMENT_MODE="$DEPLOY_MODE" \
  --env BB3_DEPLOY_WAIT_SECONDS=30 "$IMAGE")"
RUN_EXIT=0
if [[ "${BB3_DOCKER_MOCK_INPUT+x}" == x ]]; then
  if printf '%b' "$BB3_DOCKER_MOCK_INPUT" | "${DOCKER[@]}" start --attach --interactive "$CONTAINER_ID" 2>&1 | tee "$RUN_LOG"; then
    RUN_EXIT=0
  else
    RUN_EXIT=$?
  fi
else
  if "${DOCKER[@]}" start --attach --interactive "$CONTAINER_ID" 2>&1 | tee "$RUN_LOG"; then
    RUN_EXIT=0
  else
    RUN_EXIT=$?
  fi
fi
if [[ "$RUN_EXIT" != "${BB3_DOCKER_EXPECTED_EXIT:-0}" ]]; then
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
else
  expected_output+=(
    '[PULL] Pull approved main updates'
    '[DEPLOY] Run uat deployment script'
    '[VERIFY] Wait for all desired tasks and replicas to converge'
    'Skipped SERVICES.'
    'Stopped before TASKS'
  )
  ! grep -F 'docker service logs' "$RUN_LOG" >/dev/null || {
    echo 'FAIL guided n did not stop subsequent log checks' >&2; exit 1;
  }
fi
for expected in "${expected_output[@]}"; do
  grep -F "$expected" "$RUN_LOG" >/dev/null
done
if grep -E '(^|[[:space:]])(ssh|docker|git|watch): command not found' "$RUN_LOG" >/dev/null; then
  echo 'FAIL mock image unexpectedly attempted a real remote utility' >&2
  exit 1
fi
"${DOCKER[@]}" rm "$CONTAINER_ID" >/dev/null
CONTAINER_ID=''
progress 'PASS' 'The real OpenSSH client/server completed the simulated deployment sequence inside the no-network mock host.'
printf 'Full build log: %s\nFull SSH session log: %s\n' "$BUILD_LOG" "$RUN_LOG"

if [[ "${BB3_DOCKER_TEST_GUIDED:-0}" == 1 ]]; then
  progress 'GUIDED TEST' 'Second SSH session: Enter runs required steps, s skips optional SERVICES, n stops before TASKS.'
  BB3_DEPLOYMENT_MODE=guided \
    BB3_DOCKER_EXPECTED_EXIT=130 \
    BB3_DOCKER_MOCK_INPUT=$'\n\n\ns\nn\n' \
    bash "$HERE/test-bb3-deployment-docker.sh"
  exit $?
fi