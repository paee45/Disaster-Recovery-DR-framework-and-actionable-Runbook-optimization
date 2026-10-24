#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bb3-prompt.sh
source "$HERE/bb3-prompt.sh"
MOCK=false
if [[ "${1:-}" == --mock ]]; then
  MOCK=true
  shift
fi
[[ $# == 1 && "$1" =~ ^(automatic|guided)$ ]] || {
  echo 'Usage: bb3-deployment.sh [--mock] <automatic|guided>' >&2
  exit 2
}
MODE="$1"
DEPLOY_ENV="${ENV:-}"
case "$DEPLOY_ENV" in
  dev) HOST=dev-1.app.beepte.ch ;;
  uat) HOST=uat-1.app.beepte.ch ;;
  prod)
    if [[ "$MOCK" == true ]]; then HOST=live-1.app.beepte.ch
    else echo 'Production deployment is outside this UAT-role DR workflow.' >&2; exit 2
    fi ;;
  *) echo 'ENV must be dev or uat for real deployment.' >&2; exit 2 ;;
esac
[[ "$MOCK" == true || ( -t 0 && -t 1 ) ]] || { echo 'Real deployment requires a local interactive terminal.' >&2; exit 2; }
if [[ "$MOCK" == false ]]; then
  command -v ssh >/dev/null || { echo 'OpenSSH client is required.' >&2; exit 2; }
fi

WAIT_SECONDS="${BB3_DEPLOY_WAIT_SECONDS:-900}"
POLL_SECONDS="${BB3_DEPLOY_POLL_SECONDS:-5}"
[[ "$WAIT_SECONDS" =~ ^[0-9]+$ && "$WAIT_SECONDS" -ge 1 && "$WAIT_SECONDS" -le 3600 \
  && "$POLL_SECONDS" =~ ^[0-9]+$ && "$POLL_SECONDS" -ge 1 && "$POLL_SECONDS" -le 60 ]] \
  || { echo 'Deployment wait timeout/poll interval is outside the allowed range.' >&2; exit 2; }

remote_output() {
  local command="$1"
  printf '[%s] %s\n' "$HOST" "$command" >&2
  if [[ "$MOCK" == true ]]; then
    printf '[MOCK SSH] %s\n' "$HOST" >&2
    case "$command" in
      *'git branch --show-current'*)
        printf 'branch=main\nworktree=clean\ncommit=0123456789abcdef0123456789abcdef01234567\n' ;;
      *'git pull --ff-only'*) printf 'Already up to date.\n' ;;
      *'scripts/deploy.sh'*) printf 'MOCK deploy started for %s\nMOCK deploy completed\n' "$DEPLOY_ENV" ;;
      *'docker stack ps --filter'*)
        printf 'beepbeep_web.1 Running 8 seconds ago\nbeepbeep_worker.1 Running 7 seconds ago\n' ;;
      *"docker service ls --filter label=com.docker.stack.namespace=beepbeep"*) printf '2/2\n1/1\n' ;;
      *'docker service ls'*)
        printf 'NAME             MODE         REPLICAS   IMAGE\nbeepbeep_web     replicated   2/2        example:web\nbeepbeep_worker  replicated   1/1        example:worker\n' ;;
      *'docker stack ps beepbeep | grep Running'*)
        printf 'beepbeep_web.1 Running 8 seconds ago\nbeepbeep_worker.1 Running 7 seconds ago\n' ;;
      *'docker service logs'*)
        if [[ "$command" == *'grep --color=always'* ]]; then
          printf '2026-10-24T10:00:00Z mock service started\n2026-10-24T10:00:01Z warning: mock warning line\n' \
            | grep --color=always -Ei 'warning|error' || true
        else
          printf '2026-10-24T10:00:00Z mock service started\n2026-10-24T10:00:01Z warning: mock warning line\n'
        fi ;;
      *) echo 'Unknown mocked remote command; refused.' >&2; return 97 ;;
    esac
  else
    ssh "$HOST" "$command"
  fi
}

preflight="$(remote_output 'cd projects/bb3-infrastructure && branch=$(git branch --show-current) && test "$branch" = main && test -z "$(git status --porcelain)" && printf "branch=%s\\nworktree=clean\\ncommit=%s\\n" "$branch" "$(git rev-parse HEAD)"')" \
  || { echo 'Read-only preflight failed. Verify SSH host key/access, repository path, clean worktree and main branch; no deployment command was run.' >&2; exit 2; }
grep -Fx 'branch=main' <<< "$preflight" >/dev/null \
  && grep -Fx 'worktree=clean' <<< "$preflight" >/dev/null \
  && grep -Eq '^commit=[a-fA-F0-9]{40}$' <<< "$preflight" \
  || {
    echo 'Remote repository is not a clean main worktree; deployment refused.' >&2
    exit 2
  }
printf 'Deployment target: ENV=%s host=%s\n%s\n' "$DEPLOY_ENV" "$HOST" "$preflight"
if [[ "$MOCK" == true ]]; then
  printf '%s\n' 'MOCK MODE: no SSH, Docker, Git, deployment script or remote host was contacted.'
  printf 'MOCK_CONTAINER_NAME=%s (display label only; no container is created)\n' \
    "${BB3_DEPLOYMENT_CONTAINER:-bb3-deploument-ec2}"
  if [[ "$DEPLOY_ENV" == prod ]]; then
    printf '%s\n' '[MOCK COMMAND ONLY] sudo su'
  fi
else
  echo 'Remote output is streamed to this local terminal. SSH host-key checking uses the normal local known_hosts policy.'
  echo 'Review/redact logs before P3-S03 evidence confirmation; the transcript is not saved automatically.'
  bb3_prompt_token_read APPROVAL 'Type ' "DEPLOY-${DEPLOY_ENV^^}" " to authorize git pull and deployment to $HOST: "
  [[ "$APPROVAL" == "DEPLOY-${DEPLOY_ENV^^}" ]] || { echo 'Deployment not approved; no change made.' >&2; exit 2; }
fi

SKIPPED=()
REQUIRED_SKIPPED=false
run_step() {
  local key="$1" label="$2" command="$3" required="$4" response=''
  if [[ "$MODE" == guided && "$MOCK" == false ]]; then
    bb3_prompt_read response "[$key] $label [Enter=run, n=stop, s=skip]: "
    case "$response" in
      ''|y|Y|yes|YES) ;;
      n|N|no|NO) echo "Stopped before $key; no later commands will run." >&2; return 130 ;;
      s|S|skip|SKIP)
        SKIPPED+=("$key")
        [[ "$required" != true ]] || REQUIRED_SKIPPED=true
        printf 'Skipped %s.\n' "$key"
        return 0 ;;
      *) echo 'Enter, n or s only; no remote command was run.' >&2; return 2 ;;
    esac
  elif [[ "$MODE" == guided ]]; then
    printf '[MOCK GUIDED] Enter=run, n=stop, s=skip: %s\n' "$key"
  fi
  remote_output "$command"
}

steps=(
  'PULL|Pull approved main updates|cd projects/bb3-infrastructure && git pull --ff-only|required'
  "DEPLOY|Run $DEPLOY_ENV deployment script|cd projects/bb3-infrastructure && scripts/deploy.sh $DEPLOY_ENV|required"
)
for entry in "${steps[@]}"; do
  IFS='|' read -r key label remote required <<< "$entry"
  run_step "$key" "$label" "$remote" "$required"
done

wait_for_stack() {
  local started="$SECONDS" elapsed tasks services replica current_count desired_count converged
  printf '\n== WAIT: all desired tasks and service replicas ==\n'
  while ((SECONDS - started < WAIT_SECONDS)); do
    tasks="$(remote_output "docker stack ps --filter desired-state=running --format '{{.Name}} {{.CurrentState}}' beepbeep")" \
      || { echo 'Unable to inspect stack tasks; deployment result remains unconfirmed.' >&2; return 2; }
    services="$(remote_output "docker service ls --filter label=com.docker.stack.namespace=beepbeep --format '{{.Replicas}}'")" \
      || { echo 'Unable to inspect service replicas; deployment result remains unconfirmed.' >&2; return 2; }
    printf '%s\n%s\n' "$tasks" "$services"
    if [[ -n "$tasks" && -n "$services" ]] \
      && ! grep -vE 'Running([[:space:]]|$)' <<< "$tasks" >/dev/null \
      && ! grep -vE '^[0-9]+/[0-9]+$' <<< "$services" >/dev/null; then
      converged=true
      while IFS= read -r replica; do
        IFS=/ read -r current_count desired_count <<< "$replica"
        if [[ "$desired_count" == 0 || "$current_count" != "$desired_count" ]]; then converged=false; fi
      done <<< "$services"
      if [[ "$converged" == true ]]; then
        printf 'All desired tasks are Running and service replicas match.\n'
        return 0
      fi
    fi
    if [[ "$MOCK" == true ]]; then
      echo 'Mock deployment did not report convergence; failing immediately.' >&2
      return 2
    fi
    elapsed=$((SECONDS - started))
    printf '[%02d:%02d] Still waiting for stack convergence.\n' "$((elapsed / 60))" "$((elapsed % 60))"
    sleep "$POLL_SECONDS"
  done
  echo "Timed out after ${WAIT_SECONDS}s waiting for all tasks/services. Do not attest deployment convergence." >&2
  return 2
}

if [[ "$MODE" == guided && "$MOCK" == false ]]; then
  response=''
  bb3_prompt_read response '[VERIFY] Wait for all desired tasks and replicas to converge [Enter=run, n=stop, s=skip]: '
  case "$response" in
    ''|y|Y|yes|YES) wait_for_stack || exit $? ;;
    n|N|no|NO) echo 'Stopped before convergence check; no deployment attestation.' >&2; exit 130 ;;
    s|S|skip|SKIP) SKIPPED+=(VERIFY); REQUIRED_SKIPPED=true ;;
    *) echo 'Enter, n or s only; no remote command was run.' >&2; exit 2 ;;
  esac
elif [[ "$MODE" == guided ]]; then
  printf '[MOCK GUIDED] Enter=run, n=stop, s=skip: VERIFY\n'
  wait_for_stack || exit $?
else
  wait_for_stack || exit $?
fi

run_step SERVICES 'List deployed services' 'docker service ls' false || exit $?
run_step TASKS 'Show running stack tasks' 'docker stack ps beepbeep | grep Running' false || exit $?
run_step LOGS 'Show recent promo service logs' \
  'docker service logs --timestamps --since 1m beepbeep_bb3-promos 2>&1 | sort' false || exit $?
run_step WARNINGS 'Highlight warning/error log lines' \
  "docker service logs --timestamps --since 1m beepbeep_bb3-promos 2>&1 | grep --color=always -Ei 'warning|error' || true" \
  false || exit $?

if [[ "$REQUIRED_SKIPPED" == true ]]; then
  printf '\nIncomplete deployment: required steps skipped: %s\n' "${SKIPPED[*]}" >&2
  echo 'No deployment attestation may be recorded. Complete missing required work and verify actual state first.' >&2
  exit 2
fi
if ((${#SKIPPED[@]})); then printf '\nOptional checks skipped: %s\n' "${SKIPPED[*]}"; fi
printf '\n%s deployment sequence finished. App owner must review output and confirm endpoints/tasks.\n' "$MODE"
