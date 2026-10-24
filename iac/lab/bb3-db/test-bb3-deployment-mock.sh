#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
TEMP="$(cd "$TEMP" && pwd -P)"
export TEST_REMOTE_CALLED="$TEMP/remote-called"

cat > "$TEMP/stubs.bash" <<'EOF'
ssh() { touch "$TEST_REMOTE_CALLED"; return 99; }
docker() { touch "$TEST_REMOTE_CALLED"; return 99; }
git() { touch "$TEST_REMOTE_CALLED"; return 99; }
watch() { touch "$TEST_REMOTE_CALLED"; return 99; }
export -f ssh docker git watch
EOF

run_mock() {
  local environment="$1" container="$2" output="$3" host="${4:-}"
  env -i PATH="$PATH" BASH_ENV="$TEMP/stubs.bash" TEST_REMOTE_CALLED="$TEST_REMOTE_CALLED" \
    ENV="$environment" BB3_DEPLOYMENT_CONTAINER="$container" \
    BB3_DEPLOYMENT_HOST="$host" BB3_DOCKER_STACK_NAME=fixture-stack \
    bash "$HERE/bb3-deployment.sh" --mock automatic > "$output" 2>&1
}

run_mock dev dev-mock "$TEMP/dev.out"
grep -F 'Deployment target: ENV=dev host=dev-1.app.beepte.ch' "$TEMP/dev.out" >/dev/null
grep -F 'docker stack ps --filter desired-state=running --format' "$TEMP/dev.out" | grep -F 'fixture-stack' >/dev/null
grep -F 'scripts/deploy.sh dev' "$TEMP/dev.out" >/dev/null
! grep -F 'sudo su' "$TEMP/dev.out" >/dev/null
run_mock uat bb3-deploument-ec2 "$TEMP/uat.out"
grep -F 'Deployment target: ENV=uat host=uat-1.app.beepte.ch' "$TEMP/uat.out" >/dev/null
grep -F 'MOCK_CONTAINER_NAME=bb3-deploument-ec2' "$TEMP/uat.out" >/dev/null
grep -F 'scripts/deploy.sh uat' "$TEMP/uat.out" >/dev/null
run_mock prod prod-mock "$TEMP/prod.out"
grep -F 'Deployment target: ENV=prod host=live-1.app.beepte.ch' "$TEMP/prod.out" >/dev/null
grep -F '[MOCK COMMAND ONLY] sudo su' "$TEMP/prod.out" >/dev/null
grep -F 'sudo su' "$TEMP/prod.out" >/dev/null
grep -F 'scripts/deploy.sh prod' "$TEMP/prod.out" >/dev/null
if env -i PATH="$PATH" ENV=local bash "$HERE/bb3-deployment.sh" --mock automatic > /dev/null 2>&1; then
  echo 'FAIL unsupported environment accepted' >&2
  exit 1
fi
if env -i PATH="$PATH" ENV=prod bash "$HERE/bb3-deployment.sh" automatic > /dev/null 2>&1; then
  echo 'FAIL real production deployment accepted in the UAT-role workflow' >&2
  exit 1
fi
if env -i PATH="$PATH" ENV=uat BB3_DEPLOYMENT_HOST=dev-1.app.beepte.ch \
    bash "$HERE/bb3-deployment.sh" --mock automatic > /dev/null 2>&1; then
  echo 'FAIL UAT accepted a dev deployment hostname' >&2
  exit 1
fi
[[ ! -e "$TEST_REMOTE_CALLED" ]]
echo 'PASS shared deployment runner simulates environment-specific hosts and commands without invoking SSH, Docker, Git or watch'