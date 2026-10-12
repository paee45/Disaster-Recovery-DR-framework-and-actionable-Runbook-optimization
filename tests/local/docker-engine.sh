#!/usr/bin/env bash
set -euo pipefail

dr_docker_probe() {
  local context="$1" info
  info="$(docker --context "$context" info --format '{{.OSType}}' 2>/dev/null)" || return 1
  [[ "$info" == linux ]]
}

dr_docker_engine() {
  local requested="${1:-}" active candidate endpoint
  command -v docker >/dev/null || { echo "Docker CLI is missing. Install it with your preferred engine." >&2; return 2; }
  if [[ -n "$requested" ]]; then
    dr_docker_probe "$requested" || { echo "Docker context '$requested' is unavailable or is not a Linux engine." >&2; return 2; }
    export DOCKER_CONTEXT="$requested"
  elif [[ -n "${DOCKER_HOST:-}${DOCKER_CONTEXT:-}" ]]; then
    [[ "$(docker info --format '{{.OSType}}' 2>/dev/null)" == linux ]] || {
      echo "The configured DOCKER_HOST/DOCKER_CONTEXT cannot reach a Linux engine; it was not overridden." >&2
      return 2
    }
  else
    active="$(docker context show)"
    if dr_docker_probe "$active"; then
      export DOCKER_CONTEXT="$active"
    else
      while IFS= read -r candidate; do
        [[ "$candidate" == "$active" ]] && continue
        endpoint="$(docker context inspect "$candidate" --format '{{.Endpoints.docker.Host}}' 2>/dev/null)" || continue
        [[ "$endpoint" == unix://* || "$endpoint" == npipe://* ]] || continue
        if dr_docker_probe "$candidate"; then
          export DOCKER_CONTEXT="$candidate"
          echo "Active context '$active' is unavailable; using reachable local context '$candidate' for this process." >&2
          break
        fi
      done < <(docker context ls --format '{{.Name}}')
      if [[ -z "${DOCKER_CONTEXT:-}" ]]; then
        echo "No running local Linux Docker engine was found. Start your preferred engine, then retry." >&2
        echo "Examples: Docker Desktop, OrbStack, Rancher Desktop (dockerd), or Colima: colima start." >&2
        echo "For a remote engine, select it explicitly with --context NAME; it must have access to the repository path." >&2
        docker context ls >&2
        return 2
      fi
    fi
  fi
  docker info --format 'Engine: {{.Name}} | {{.OSType}}/{{.Architecture}} | {{.ServerVersion}}'
  echo "Context: ${DOCKER_CONTEXT:-DOCKER_HOST}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  requested=""
  case "${1:-}" in
    --context) [[ $# == 2 ]] || { echo "Usage: bash tests/local/docker-engine.sh [--context NAME]" >&2; exit 2; }; requested="$2" ;;
    --help|-h) echo "Usage: bash tests/local/docker-engine.sh [--context NAME]"; exit 0 ;;
    "") ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  dr_docker_engine "$requested"
fi