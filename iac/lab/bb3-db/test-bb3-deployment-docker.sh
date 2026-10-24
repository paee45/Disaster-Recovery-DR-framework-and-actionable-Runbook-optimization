#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TEMP="$(mktemp -d)"
TEMP="$(cd "$TEMP" && pwd -P)"
IMAGE="bb3-deployment-mock:test-$$"
CONTAINER="${BB3_DEPLOYMENT_CONTAINER:-bb3-deploument-ec2}"
CONTAINER_ID=''
DOCKER=(docker)
if [[ -n "${DOCKER_CONTEXT:-}" ]]; then DOCKER+=(--context "$DOCKER_CONTEXT"); fi
cleanup() {
  if [[ -n "$CONTAINER_ID" ]]; then "${DOCKER[@]}" rm -f "$CONTAINER_ID" >/dev/null 2>&1 || true; fi
  "${DOCKER[@]}" image rm "$IMAGE" >/dev/null 2>&1 || true
  rm -rf "$TEMP"
}
trap cleanup EXIT

mkdir "$TEMP/context"
cp "$HERE/docker-mock/Dockerfile" "$HERE/bb3-deployment.sh" "$HERE/bb3-prompt.sh" "$TEMP/context/"
[[ "$(find "$TEMP/context" -type f | wc -l | tr -d ' ')" == 3 ]]

"${DOCKER[@]}" build --tag "$IMAGE" "$TEMP/context"
CONTAINER_ID="$("${DOCKER[@]}" create --name "$CONTAINER" --network none --read-only --cap-drop ALL \
  --security-opt no-new-privileges --pids-limit 32 \
  --env ENV=uat --env BB3_DEPLOYMENT_CONTAINER="$CONTAINER" \
  --env BB3_DEPLOY_WAIT_SECONDS=30 "$IMAGE" --mock automatic)"
"${DOCKER[@]}" start --attach "$CONTAINER_ID" > "$TEMP/output"
[[ "$("${DOCKER[@]}" inspect --format '{{.State.ExitCode}}' "$CONTAINER_ID")" == 0 ]]

for expected in \
  'MOCK MODE: no SSH, Docker, Git, deployment script or remote host was contacted.' \
  'MOCK_CONTAINER_NAME=bb3-deploument-ec2' \
  'Already up to date.' \
  'MOCK deploy started for uat' \
  'All desired tasks are Running and service replicas match.' \
  'beepbeep_web     replicated   2/2' \
  'warning: mock warning line' \
  'automatic deployment sequence finished.'; do
  grep -F "$expected" "$TEMP/output" >/dev/null
done
if grep -E '(^|[[:space:]])(ssh|docker|git|watch): command not found' "$TEMP/output" >/dev/null; then
  echo 'FAIL mock image unexpectedly attempted a real remote utility' >&2
  exit 1
fi
"${DOCKER[@]}" rm "$CONTAINER_ID" >/dev/null
CONTAINER_ID=''
echo 'PASS Docker mock ran the real deployment orchestrator with no network, mounts, SSH or Docker CLI'