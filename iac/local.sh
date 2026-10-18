#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE="$ROOT/tests/local/.state"
usage() {
  printf '%s\n' \
    'Usage: bash iac/local.sh create|doctor|prepare|ready|shell|test|dr [S3|S4]|failback [<change-id>]' \
    '       bash iac/local.sh unfence <DR_ID> <local-db-id>' \
    '       bash iac/local.sh <platform|mock|addons|workloads|normalization> <terraform arguments...>' \
    'Build order: platform plan/apply, prepare, mock plan/apply, addons plan/apply, workloads plan/apply.' \
    'Always plan -out=NAME.plan, review, then apply NAME.plan. State is local, not real S3.' \
    'Default Docker context: colima-dr-framework (colima start --profile dr-framework).' \
    'An explicit DOCKER_CONTEXT is respected. Platform supports local Unix sockets only, not Windows/remote endpoints.' \
    'ready waits for existing fixtures. unfence restores saved fence state only; it does not reconcile data or cut over.'
}
[[ $# -gt 0 ]] || { usage; exit 0; }
case "$1" in --help|-h) usage; exit 0 ;; esac
# shellcheck source=tests/local/docker-engine.sh
source "$ROOT/tests/local/docker-engine.sh"
dr_docker_engine "${DOCKER_CONTEXT:-colima-dr-framework}"
stage="$1"; shift
mkdir -p "$STATE/evidence"
runner() { docker exec -i drtest-tools "$@"; }
dr_runner() {
  local name command=(docker exec -it)
  for name in SNAPSHOT_ID FENCE RESTORED_DB OLD_DB T0_AT BAD_TS RESTORE_TS RESTORE_MODE E2E_REF DR_ID DR_SELECTOR; do
    if declare -p "$name" >/dev/null 2>&1; then
      command+=(-e "$name=${!name}")
    fi
  done
  "${command[@]}" drtest-tools bash /workspace/iac/local/dr.sh "$@"
}
create_local_lab() {
  local stage stamp host_plan plan_file plan_json answer
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  for stage in platform mock addons workloads; do
    host_plan="$STATE/create-${stage}-${stamp}.plan"
    if [[ "$stage" == platform ]]; then
      plan_file="$host_plan"
    else
      plan_file="/workspace/tests/local/.state/$(basename "$host_plan")"
    fi
    bash "$ROOT/iac/local.sh" "$stage" plan "-out=$plan_file"
    if [[ "$stage" == platform ]]; then
      plan_json="$(terraform -chdir="$ROOT/iac/local/platform" show -json "$plan_file")"
    else
      plan_json="$(runner terraform -chdir="/workspace/iac/local/$stage" show -json "$plan_file")"
    fi
    jq -r '
      .resource_changes // [] |
      if length == 0 then "No resource changes."
      else
        group_by(.change.actions | join(","))[] |
        "\(.[0].change.actions | join(",")): \(length)\n" + (map(.address) | join("\n"))
      end
    ' <<<"$plan_json"
    read -r -p "Type APPLY to apply the reviewed $stage plan (anything else stops): " answer
    [[ "$answer" == APPLY ]] || { printf 'Stopped; saved plan: %s\n' "$plan_file"; return 2; }
    bash "$ROOT/iac/local.sh" "$stage" apply "$plan_file"
    if [[ "$stage" == platform ]]; then
      bash "$ROOT/iac/local.sh" prepare
    fi
  done
  bash "$ROOT/iac/local.sh" ready
}
case "$stage" in
  create)
    [[ $# == 0 ]] || { usage; exit 2; }
    create_local_lab
    ;;
  doctor)
    docker ps --filter name=drtest --format '{{.Names}} {{.Status}}'
    ;;
  platform)
    command -v terraform >/dev/null || { echo 'Install Terraform on the host for the container platform.' >&2; exit 2; }
    export TF_VAR_repository_path="$ROOT"
    endpoint="${DOCKER_HOST:-}"
    if [[ -n "${DOCKER_CONTEXT:-}" || -z "$endpoint" ]]; then
      endpoint="$(docker context inspect "${DOCKER_CONTEXT:-$(docker context show)}" --format '{{.Endpoints.docker.Host}}')"
    fi
    [[ "$endpoint" == unix://* ]] || { echo 'This wrapper currently supports local Unix sockets only. Windows/remote endpoints need separate validation.' >&2; exit 2; }
    export TF_VAR_docker_host="$endpoint"
    case "$(docker info --format '{{.Architecture}}')" in
      aarch64|arm64) export TF_VAR_tool_arch=arm64 ;;
      x86_64|amd64) export TF_VAR_tool_arch=amd64 ;;
      *) echo 'Unsupported Docker architecture.' >&2; exit 2 ;;
    esac
    unset TF_VAR_aws_profile TF_VAR_account_id TF_VAR_state_bucket TF_VAR_region
    state_context="${DOCKER_CONTEXT:-local}"
    [[ "$state_context" =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'Unsafe Docker context name for state path.' >&2; exit 2; }
    terraform -chdir="$ROOT/iac/local/platform" init -reconfigure -input=false \
      -backend-config="path=$STATE/platform-${state_context}.tfstate"
    terraform -chdir="$ROOT/iac/local/platform" "$@"
    ;;
  prepare)
    ready=0
    for ((attempt=1; attempt<=90; attempt++)); do
      if docker exec drtest-k3s kubectl --context default --request-timeout=5s get --raw=/readyz >/dev/null 2>&1 \
        && docker exec drtest-k3s kubectl --context default --request-timeout=5s get nodes -o json \
          | jq -e '.items | length > 0' >/dev/null 2>&1; then ready=1; break; fi
      printf 'Waiting for local Kubernetes (%s/90)\n' "$attempt"
      if ((attempt < 90)); then sleep 2; fi
    done
    [[ "$ready" == 1 ]] || { echo 'Local Kubernetes did not start.' >&2; exit 1; }
    docker cp drtest-k3s:/etc/rancher/k3s/k3s.yaml "$STATE/kubeconfig"
    runner bash /workspace/iac/local/prepare.sh
    ;;
  ready)
    runner bash -s <<'READY'
set -euo pipefail
export KUBECONFIG=/workspace/tests/local/.state/kubeconfig
if kubectl --context dr-local --request-timeout=10s api-resources --api-group=external-secrets.io -o name | grep -Fx externalsecrets.external-secrets.io >/dev/null; then
  if kubectl --context dr-local --request-timeout=10s -n app get externalsecret/app-db-credentials >/dev/null 2>&1; then
    kubectl --context dr-local --request-timeout=10s -n app wait \
      --for=condition=Ready externalsecret/app-db-credentials --timeout=180s
  fi
fi
workloads="$(kubectl --context dr-local --request-timeout=10s -n app get deployment,statefulset -o name)"
for workload in deployment/app-a statefulset/app-b deployment/app-c deployment/app-d deployment/app-e; do
  name="${workload##*/}"
  if grep -E "/${name}$" <<<"$workloads" >/dev/null; then
    kubectl --context dr-local --request-timeout=10s -n app rollout status "$workload" --timeout=180s
  fi
done
kubectl --context dr-local --request-timeout=10s -n reloader rollout status deployment/reloader-alert-sink --timeout=180s
READY
    ;;
  mock|addons|workloads|normalization)
    runner terraform -chdir="/workspace/iac/local/$stage" init -input=false
    runner terraform -chdir="/workspace/iac/local/$stage" "$@"
    ;;
  shell)
    docker exec -it drtest-tools bash
    ;;
  test)
    runner bash /workspace/tests/local/run-tests.sh
    ;;
  dr)
    scenario="${1:-S3}"; [[ "$scenario" == S3 || "$scenario" == S4 ]] || { usage; exit 2; }
    shift || true
    dr_runner "$scenario" "$@"
    ;;
  failback)
    [[ $# -le 1 ]] || { usage; exit 2; }
    dr_runner failback "$@"
    ;;
  unfence)
    [[ $# == 2 && "$1" =~ ^DR-[A-Za-z0-9][A-Za-z0-9._-]{0,100}$ \
      && "$2" =~ ^app-pg-local(-[A-Za-z0-9][A-Za-z0-9-]*)?$ ]] \
      || { echo 'Usage: unfence <DR_ID> <app-pg-local[-suffix]>' >&2; exit 2; }
    runner bash -s -- "$1" "$2" <<'UNFENCE'
set -euo pipefail
set +x
original_id="$1"; database="$2"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_ENDPOINT_URL
unset SECRET_MODE DR_GUARD_OK DR_EVIDENCE_DIR DR_TIMELINE DR_AUDIT_LOG DR_ID DR_ACTOR
source /workspace/tests/local/.state/local.env
[[ "$DR_ENV" == local && "$AWS_PROFILE" == dr-local && "$ACCOUNT_ID" == 000000000000 \
  && "$EKS_CONTEXT" == dr-local && "$DR_ENDPOINT_MAP" == /workspace/tests/local/.state/endpoint-map ]] \
  || { echo 'REFUSED: generated local fixture environment required.' >&2; exit 2; }
export DR_ID="$original_id" DR_EVIDENCE_DIR="/workspace/evidence/$original_id"
export DR_TIMELINE="$DR_EVIDENCE_DIR/timeline.jsonl"
[[ -f "$DR_TIMELINE" && ( -f "$DR_EVIDENCE_DIR/db/fence-$database.readonly" \
  || -f "$DR_EVIDENCE_DIR/db/fence-$database.sgs.json" ) ]] \
  || { echo 'REFUSED: original timeline and saved fence state are required.' >&2; exit 2; }
source /workspace/automation/scripts/dr-lib.sh
dr_guard || exit 2
bash /workspace/automation/scripts/dr-fence-instance.sh restore "$database"
echo 'Saved fence restored. No data reconciliation or endpoint cutover was performed.'
UNFENCE
    ;;
  *) usage; exit 2 ;;
esac