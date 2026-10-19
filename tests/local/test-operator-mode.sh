#!/usr/bin/env bash
set -o pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  echo 'Bash 4+ required; on macOS use /opt/homebrew/bin/bash.' >&2
  exit 2
fi
command -v jq >/dev/null || { echo 'jq required (no dependencies installed).' >&2; exit 2; }
REAL_JQ="$(command -v jq)"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SOURCE="$ROOT/automation/scripts"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dr-operator-tests.XXXXXX")" || exit 2
trap 'rm -rf "$TMP"' EXIT
PASSN=0; FAILN=0

extract_function() {
  local source_file="$1" function_name="$2" code
  code="$(sed -n "/^${function_name}() {/,/^}/p" "$source_file")"
  [[ -n "$code" ]] || { echo "Missing source function: $source_file:$function_name" >&2; return 2; }
  printf '%s\n' "$code"
}
for function_name in dr_app_secret _dr_pgpass_add; do
  function_code="$(extract_function "$SOURCE/dr-lib.sh" "$function_name")" || exit 2
  eval "$function_code" || exit 2
done
for function_name in ask gate fence db_verify connections e2e; do
  function_code="$(extract_function "$SOURCE/dr-run.sh" "$function_name")" || exit 2
  eval "$function_code" || exit 2
done
for function_name in capture validate_pg; do
  function_code="$(extract_function "$SOURCE/dr-restore.sh" "$function_name")" || exit 2
  eval "$function_code" || exit 2
done
function_code="$(extract_function "$SOURCE/dr-fence-instance.sh" master_psql)" || exit 2
eval "$function_code" || exit 2

trace() { printf '%s\n' "$*" >> "$CALLS"; }
forbidden() { trace "FORBIDDEN $*"; return 98; }
aws() {
  [[ "$1" == --profile && "$2" == "$AWS_PROFILE" && "$3" == --region && "$4" == "$AWS_REGION" ]] \
    || { forbidden 'unpinned aws'; return 97; }
  shift 4
  case "$*" in
    'rds describe-db-instances '*"--query DBInstances[0].DBInstanceStatus --output text")
      trace 'aws status'; printf '%s\n' "$DB_STATUS"; return "$API_RC" ;;
    'rds describe-db-instances '*"--query DBInstances[0] --output json")
      trace 'aws instance'; printf '%s\n' '{"DBInstanceArn":"offline-resource","DBInstanceIdentifier":"offline-old"}' ;;
    'rds list-tags-for-resource --resource-name offline-resource --query TagList --output json')
      trace 'aws tags'; printf '%s\n' '[]' ;;
    'secretsmanager get-secret-value '*)
      if [[ "$DR_DB_ACCESS" == none ]]; then forbidden get-secret-value; return 98; fi
      trace 'sql get-secret-value'; printf '%s\n' '{"username":"offline","password":"fixture-only"}' ;;
    *) forbidden "aws $*" ;;
  esac
}
kubectl() {
  if [[ -n "${CONSUMER_CASE:-}" ]]; then
    [[ "$*" == "--context $EKS_CONTEXT --request-timeout=20s -n $K8S_NS get "* ]] \
      || { forbidden "kubectl $*"; return 98; }
    case "${*:7}" in
      "secret $K8S_SECRET -o json --show-managed-fields")
        trace 'kube consumer secret'
        jq '.metadata.managedFields = [{"fieldsV1":{"f:data":{}},"time":"2026-10-19T00:00:00Z"}]' <<<"$ENDPOINT_SECRET" ;;
      'deploy,statefulset,daemonset,cronjob -o json')
        trace 'kube consumer inventory'
        [[ "$CONSUMER_CASE" != denied ]] || { echo 'Forbidden: offline inventory denied' >&2; return 1; }
        if [[ "$CONSUMER_CASE" == empty ]]; then printf '%s\n' '{"items":[]}'
        else printf '%s\n' '{"items":[{"kind":"Deployment","metadata":{"name":"offline-app"},"spec":{"selector":{"matchLabels":{"app":"offline"}},"template":{"spec":{"containers":[{"envFrom":[{"secretRef":{"name":"endpoint-only"}}]}]}}}}]}' ; fi ;;
      'pods -l app=offline --field-selector=status.phase=Running -o json')
        trace 'kube consumer pods'
        printf '%s\n' '{"items":[{"metadata":{},"status":{"startTime":"2026-10-19T00:01:00Z"}}]}' ;;
      *) forbidden "kubectl $*" ;;
    esac
    return $?
  fi
  [[ "$*" == "--context $EKS_CONTEXT -n $K8S_NS get secret $K8S_SECRET -o json" ]] \
    || { forbidden "kubectl $*"; return 98; }
  trace 'kube endpoint'; printf '%s\n' "$ENDPOINT_SECRET"
}
psql() {
  [[ "$DR_DB_ACCESS" != none && "$ALLOW_SQL" == 1 ]] || { forbidden psql; return 98; }
  trace 'sql psql'; printf '%s\n' "$PSQL_OUTPUT"; return "$PSQL_RC"
}
pg_dump() { forbidden pg_dump; }
dr_guard() { return 0; }
dr_confirm() { trace confirm; return 0; }
dr_endpoint() { trace "endpoint $1"; printf '%s\n' "$RESOLVED_ENDPOINT"; return "$ENDPOINT_RC"; }
dr_dsn() {
  [[ "$DR_DB_ACCESS" != none && "$ALLOW_SQL" == 1 ]] || { forbidden dr_dsn; return 98; }
  trace "sql dr_dsn $1"; printf '%s\n' 'host=offline.invalid dbname=app'
}
dr_set_target() { forbidden dr_set_target; }
dr_mark() { trace "mark $1"; }
dr_mark_once() { dr_mark "$@"; }
has_tty() { return 1; }
save_vars() { trace save_vars; }
target() {
  [[ "$DR_DB_ACCESS" != none && "$ALLOW_SQL" == 1 ]] || { forbidden target; return 98; }
  trace 'sql target'; TARGET_DSN='host=offline.invalid dbname=app'
}
dr_run() {
  [[ "$DR_DB_ACCESS" != none && "$ALLOW_SQL" == 1 ]] || { forbidden "dr_run $*"; return 98; }
  trace "run $1 ${2##*/}"; return 0
}
x() {
  local script_name="${1##*/}" command_name="${2:-}"
  trace "x $script_name ${*:2}"
  case "$script_name $command_name" in
    'dr-restore.sh validate') return "$VALIDATE_RC" ;;
    'dr-fence-instance.sh wait-stopped'|'dr-fence-instance.sh verify-quarantine') return "$ISOLATION_RC" ;;
    'dr-secret-cutover.sh verify-routing') return "$ROUTING_RC" ;;
    'dr-eks-rollout.sh check') return "$ROLLOUT_RC" ;;
    'dr-secret-cutover.sh precheck')
      [[ "$DR_DB_ACCESS" != none && "$ALLOW_SQL" == 1 ]] || { forbidden precheck; return 98; }
      if (( PRECHECK_FAILURES > 0 )); then PRECHECK_FAILURES=$((PRECHECK_FAILURES - 1)); return 1; fi ;;
    'dr-secret-cutover.sh fix-password'|'dr-restore.sh validate-pg')
      [[ "$DR_DB_ACCESS" != none && "$ALLOW_SQL" == 1 ]] || { forbidden "$command_name"; return 98; } ;;
    *) forbidden "runner x $*" ;;
  esac
}

MIRROR="$TMP/repo/automation/scripts"
mkdir -p "$MIRROR" "$TMP/bin" || exit 2
for script_name in dr-secret-cutover.sh dr-restore.sh dr-fence-instance.sh dr-verify.sh k8s-secret-consumers.sh rds-requests.jq; do
  cp "$SOURCE/$script_name" "$MIRROR/$script_name" || exit 2
done
sed -n '/^export DR_DB_ACCESS="${DR_DB_ACCESS:-none}"$/,/^# one run =/p' "$SOURCE/dr-run.sh" > "$TMP/resume-mode.sh"
[[ -s "$TMP/resume-mode.sh" ]] || exit 2
printf '\nprintf "resume-mode=%%s\\n" "$DR_DB_ACCESS"\n' >> "$TMP/resume-mode.sh"
declare -f trace forbidden aws kubectl psql pg_dump dr_guard dr_confirm dr_endpoint dr_dsn \
  dr_set_target dr_mark dr_mark_once dr_app_secret _dr_pgpass_add > "$MIRROR/dr-lib.sh"
for script_name in dr-eks-rollout.sh k8s-secret-endpoint.sh; do
  {
    printf '#!/usr/bin/env bash\nsource %q\n' "$MIRROR/dr-lib.sh"
    printf 'trace "%s $*"\n' "$script_name"
    printf 'case "$*" in\n'
    if [[ "$script_name" == dr-eks-rollout.sh ]]; then
      printf '  "snapshot-generations $K8S_SECRET"|"wait $K8S_SECRET") exit 0 ;;\n'
    else
      printf '  *" set --host restored.invalid --port 5432 --db-id offline-restored --from-db-id offline-old --id offline-test") exit 0 ;;\n'
    fi
    printf '  *) forbidden "unexpected mirror child $*"; exit 98 ;;\nesac\n'
  } > "$MIRROR/$script_name"
  chmod +x "$MIRROR/$script_name"
done
for command_name in aws kubectl psql pg_dump docker terraform helm curl pg_isready; do
  {
    printf '#!/usr/bin/env bash\nsource %q\n' "$MIRROR/dr-lib.sh"
    case "$command_name" in
      aws|kubectl|psql|pg_dump) printf '%s "$@"\n' "$command_name" ;;
      *) printf 'forbidden %q\n' "$command_name" ;;
    esac
  } > "$TMP/bin/$command_name"
  chmod +x "$TMP/bin/$command_name"
done
ln -s "$BASH" "$TMP/bin/bash" || exit 2
export PATH="$TMP/bin:$PATH"

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
reject_with() {
  local expected="$1" result=0; shift
  "$@" || result=$?
  [[ "$result" == "$expected" ]] || { echo "Expected exit $expected, got $result: $*"; return 1; }
}
no_marker() { ! grep -Fx "mark $1" "$CALLS" >/dev/null; }
clean_sentinels() {
  if grep -F 'FORBIDDEN ' "$CALLS" >/dev/null; then cat "$CALLS"; return 1; fi
  local cache_files
  cache_files="$(find "$CASE_DIR" \( -name .pgpass -o -name pgpass -o -name pgpass.tmp -o -name .pgpass.tmp \) -print)"
  [[ -z "$cache_files" ]] || { printf 'Credential cache created:\n%s\n' "$cache_files"; return 1; }
}
test_case() {
  local name="$1"; shift
  local case_dir="$TMP/case-$((PASSN + FAILN + 1))"
  mkdir -p "$case_dir/home" "$case_dir/db" "$case_dir/aws" "$case_dir/k8s" "$case_dir/approvals" "$case_dir/baselines" || exit 2
  if (
    export CASE_DIR="$case_dir" CALLS="$case_dir/calls" HOME="$case_dir/home"
    export XDG_RUNTIME_DIR="$HOME" PGPASSFILE="$HOME/.pgpass"
    export DR_EVIDENCE_DIR="$case_dir" DR_DB_ACCESS=none DR_ENV=uat DR_ID=offline-test
    export AWS_PROFILE=offline-stub AWS_REGION=ap-southeast-1 EKS_CONTEXT=offline-stub
    export K8S_NS=offline K8S_SECRET=endpoint-only K8S_HOST_KEY=DB_HOST1,DB_HOST2 K8S_PORT_KEY=DB_PORT
    export SECRET_MODE=k8s SECRET_ID=offline-app MASTER_SECRET_ID=offline-master
    export OLD_DB=offline-old RESTORED_DB=offline-restored TARGET_DB=offline-restored PRIMARY_DB=offline-old
    export RESOLVED_ENDPOINT='restored.invalid 5432' ENDPOINT_RC=0 DB_STATUS=available API_RC=0
    export ENDPOINT_SECRET='{"data":{"DB_HOST1":"cmVzdG9yZWQuaW52YWxpZA==","DB_HOST2":"cmVzdG9yZWQuaW52YWxpZA==","DB_PORT":"NTQzMg=="}}'
    export ALLOW_SQL=0 PSQL_OUTPUT='' PSQL_RC=0 DR_ACTOR=offline-owner
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_DEFAULT_PROFILE
    unset CUTOVER_SECRET CUTOVER_ID SECRET_ID_RO K8S_SECRET_RO TARGET_DSN OLD_DSN DR_RUN_AUTO_NO
    unset DR_ENDPOINT_MAP BASELINE_S3_URI BASELINE_FILE DR_TIMELINE PG_VALIDATE_IGNORE
    unset APP_OWNER APP_DB_DESTINATION E2E_REF GATE_APPROVER CONSUMER_CASE
    export S="$SOURCE" AUTO=0 FENCE=stop VERIFY_TABLES=public.orders
    VALIDATE_RC=0; ISOLATION_RC=0; ROUTING_RC=0; ROLLOUT_RC=0; PRECHECK_FAILURES=0
    export BASELINE_DIR="$case_dir/baselines" OUT="$case_dir/aws" DB=offline-old
    : > "$CALLS"
    result=0
    "$@" || result=$?
    clean_sentinels || result=1
    exit "$result"
  ) > "$case_dir/output" 2>&1; then
    PASSN=$((PASSN + 1)); printf 'PASS %s\n' "$name"
  else
    FAILN=$((FAILN + 1)); printf 'FAIL %s\n' "$name"
    sed 's/^/  /' "$case_dir/output"
    if [[ -f "$case_dir/calls" ]]; then sed 's/^/  trace: /' "$case_dir/calls"; fi
  fi
}

secret_refused() { SECRET_MODE="$1"; reject dr_app_secret && expect_trace ''; }
cache_refused() { reject _dr_pgpass_add offline.invalid 5432 app offline fixture-only && expect_trace ''; }
sql_guard() { reject "$1" && expect_trace ''; }
script_refused() {
  local script_name="$1"; shift
  reject_with 2 "$BASH" "$MIRROR/$script_name" "$@" && expect_trace ''
}
fence_refused() {
  reject "$BASH" "$MIRROR/dr-fence-instance.sh" readonly offline-old &&
    expect_trace confirm && no_marker FENCE && [[ ! -e "$DR_EVIDENCE_DIR/db/fence-offline-old.readonly" ]]
}
quarantine_refused() {
  FENCE=quarantine
  reject fence && expect_trace '' && no_marker FENCE
}
verify_db() {
  local argument="${1:-}"
  if [[ "$argument" == settings-only ]]; then db_verify settings-only || return 1
  else db_verify || return 1; fi
  [[ "$TARGET_DB" == "$RESTORED_DB" && -z "${TARGET_DSN:-}" ]] &&
    expect_trace $'x dr-restore.sh validate offline-restored\nmark DATABASE_API_VERIFIED'
}
verify_db_failure() {
  VALIDATE_RC=42
  reject db_verify && expect_trace 'x dr-restore.sh validate offline-restored' && no_marker DATABASE_API_VERIFIED
}
runner_connections() {
  FENCE="$1"
  connections || return 1
  local expected='x dr-fence-instance.sh wait-stopped offline-old'
  [[ "$FENCE" != quarantine ]] || expected='x dr-fence-instance.sh verify-quarantine offline-old'
  expect_trace "$expected"$'\nx dr-secret-cutover.sh verify-routing\nx dr-eks-rollout.sh check\nmark ROUTING_VERIFIED'
}
connections_failure() {
  case "$1" in isolation) ISOLATION_RC=42 ;; routing) ROUTING_RC=42 ;; rollout) ROLLOUT_RC=42 ;; esac
  reject connections && no_marker ROUTING_VERIFIED
}
owner_e2e() {
  APP_OWNER='auto (local test bed)'; APP_DB_DESTINATION="$RESTORED_DB"; E2E_REF=offline-transaction
  AUTO=1
  case "$1" in
    missing-owner) unset APP_OWNER ;;
    empty-owner) APP_OWNER='' ;;
    whitespace-owner) APP_OWNER=$' \t ' ;;
    wrong-owner) APP_OWNER=offline-owner ;;
    wrong-destination) APP_DB_DESTINATION=offline-old ;;
    missing-destination) unset APP_DB_DESTINATION ;;
    missing-reference) unset E2E_REF ;;
    empty-reference) E2E_REF='' ;;
    whitespace-reference) E2E_REF=$' \t ' ;;
    denied) export DR_RUN_AUTO_NO=E2E-APP-OWNER ;;
    no-approval) AUTO=0 ;;
    routing) ROUTING_RC=42 ;;
    rollout) ROLLOUT_RC=42 ;;
    isolation) ISOLATION_RC=42 ;;
  esac
  case "$1" in
    confirmed-yes|confirmed-short|declined-destination|blank-confirmation|invalid-confirmation)
      local confirmation_answer=yes confirmation_checks=0
      case "$1" in
        confirmed-short) confirmation_answer=Y ;;
        declined-destination) confirmation_answer=no ;;
        blank-confirmation) confirmation_answer='' ;;
        invalid-confirmation) confirmation_answer=offline-restored ;;
      esac
      printf '%s\n' "$confirmation_answer" > "$CASE_DIR/destination-input"
      eval "$(extract_function "$SOURCE/dr-run.sh" e2e | sed 's|</dev/tty|< "$CASE_DIR/destination-input"|g')" || return 1
      has_tty() { confirmation_checks=$((confirmation_checks + 1)); (( confirmation_checks == 1 )); }
      tty_prompt() { :; }
      ;;
  esac
  if [[ "$1" == success || "$1" == missing-destination || "$1" == confirmed-yes || "$1" == confirmed-short ]]; then
    e2e || return 1
    [[ "$GATE_APPROVER" == "$APP_OWNER" && "$APP_DB_DESTINATION" == "$RESTORED_DB" && -n "$E2E_REF" ]] &&
      grep -Fx 'answer: GO' "$DR_EVIDENCE_DIR/approvals/E2E-APP-OWNER.txt" >/dev/null &&
      expect_trace $'x dr-fence-instance.sh wait-stopped offline-old\nx dr-fence-instance.sh wait-stopped offline-old\nx dr-secret-cutover.sh verify-routing\nx dr-eks-rollout.sh check\nmark ROUTING_VERIFIED\nsave_vars\nmark DECISION\nmark T9'
  else
    reject e2e && no_marker T9 || return 1
    if [[ "$1" == denied ]]; then
      grep -Fx 'answer: NO' "$DR_EVIDENCE_DIR/approvals/E2E-APP-OWNER.txt" >/dev/null
    elif [[ "$1" == wrong-owner ]]; then
      [[ "$GATE_APPROVER" != "$APP_OWNER" ]] &&
        grep -Fx 'answer: GO' "$DR_EVIDENCE_DIR/approvals/E2E-APP-OWNER.txt" >/dev/null
    else
      [[ ! -e "$DR_EVIDENCE_DIR/approvals/E2E-APP-OWNER.txt" ]]
    fi
  fi
}
resume_mode() {
  local requested="$1" saved="$2" expected="$3" result=0
  local saved_vars="$CASE_DIR/evidence/offline-resume/run-vars.env"
  mkdir -p "${saved_vars%/*}" || return 1
  : > "$saved_vars"
  [[ "$saved" == legacy ]] || printf 'export DR_DB_ACCESS=%q\n' "$saved" > "$saved_vars"
  ROOT="$CASE_DIR" RESUME=offline-resume DR_DB_ACCESS="$requested" \
    "$BASH" "$TMP/resume-mode.sh" > "$CASE_DIR/resume-output" 2>&1 || result=$?
  [[ "$result" == "$expected" ]] || { cat "$CASE_DIR/resume-output"; return 1; }
  if (( expected == 0 )); then
    grep -Fx "resume-mode=$requested" "$CASE_DIR/resume-output" >/dev/null
  else
    grep -F 'REFUSED: resume cannot change validation modes' "$CASE_DIR/resume-output" >/dev/null &&
      ! grep -F 'resume-mode=' "$CASE_DIR/resume-output" >/dev/null
  fi && expect_trace ''
}
consumer_inventory() {
  export CONSUMER_CASE="$1" REQUIRE_CLUSTER_IDENTITY=false
  local result=0
  "$BASH" "$MIRROR/k8s-secret-consumers.sh" check > "$CASE_DIR/consumer-output" 2>&1 || result=$?
  if [[ "$1" == success ]]; then
    [[ "$result" == 0 ]] && grep -Fx 'stale=0' "$CASE_DIR/consumer-output" >/dev/null &&
      expect_trace $'kube consumer secret\nkube consumer inventory\nkube consumer pods'
  else
    [[ "$result" == 3 ]] && ! grep -Fx 'stale=0' "$CASE_DIR/consumer-output" >/dev/null &&
      expect_trace $'kube consumer secret\nkube consumer inventory' || return 1
    if [[ "$1" == denied ]]; then
      grep -F 'ERROR: consumer inventory failed' "$CASE_DIR/consumer-output" >/dev/null
    else
      grep -F 'ERROR: no active endpoint consumers found' "$CASE_DIR/consumer-output" >/dev/null
    fi
  fi
}
baseline_capture() {
  local captured
  captured="$(capture offline-old)" || return 1
  jq -e '.source == "offline-old" and .pgSettings == {}' "$captured" >/dev/null &&
    [[ -f "$BASELINE_DIR/baseline-offline-old.json" ]] && expect_trace $'aws instance\naws tags'
}
cutover() { "$BASH" "$MIRROR/dr-secret-cutover.sh" "$@"; }
cutover_shape() {
  case "$1" in
    mixed) ENDPOINT_SECRET="$(jq '.data.POSTGRES_DB_PASSWORD = "Zml4dHVyZS1vbmx5"' <<<"$ENDPOINT_SECRET")" ;;
    extra-key) ENDPOINT_SECRET="$(jq '.data.UNRELATED = "Zml4dHVyZQ=="' <<<"$ENDPOINT_SECRET")" ;;
    missing-key) ENDPOINT_SECRET="$(jq 'del(.data.DB_HOST2)' <<<"$ENDPOINT_SECRET")" ;;
    empty-host) ENDPOINT_SECRET="$(jq '.data.DB_HOST2 = ""' <<<"$ENDPOINT_SECRET")" ;;
    credential-key) K8S_HOST_KEY=POSTGRES_DB_PASSWORD ;;
    duplicate-key) K8S_HOST_KEY=DB_HOST1,DB_HOST1 ;;
  esac
  reject cutover apply && ! grep -F 'k8s-secret-endpoint.sh ' "$CALLS" >/dev/null && no_marker T6
}
cutover_mode() {
  case "$1" in eso) SECRET_MODE=eso ;; ro) export CUTOVER_SECRET=ro ;; esac
  reject_with 2 cutover apply && expect_trace ''
}
apply_endpoint() {
  cutover apply || return 1
  expect_trace $'endpoint offline-restored\nkube endpoint\naws status\nconfirm\nkube endpoint\ndr-eks-rollout.sh snapshot-generations endpoint-only\nk8s-secret-endpoint.sh --context offline-stub -n offline -s endpoint-only -k DB_HOST1,DB_HOST2 --port-key DB_PORT set --host restored.invalid --port 5432 --db-id offline-restored --from-db-id offline-old --id offline-test\nmark SECRET_UPDATED:offline/endpoint-only\nmark T6\ndr-eks-rollout.sh wait endpoint-only\nmark T7'
}
target_rejected() {
  local command_name="$1" variant="$2"
  case "$variant" in
    unavailable) DB_STATUS=creating ;;
    api-failure) API_RC=42 ;;
    invalid-port) RESOLVED_ENDPOINT='restored.invalid invalid' ;;
    no-host) RESOLVED_ENDPOINT='None 5432' ;;
    endpoint-failure) ENDPOINT_RC=42 ;;
    original) TARGET_DB="$OLD_DB" ;;
  esac
  reject cutover "$command_name" && no_marker T6 && no_marker T7 &&
    ! grep -F 'k8s-secret-endpoint.sh ' "$CALLS" >/dev/null
}
routing_check() {
  case "$1" in
    first-host) ENDPOINT_SECRET="$(jq '.data.DB_HOST1 = "b2xkLmludmFsaWQ="' <<<"$ENDPOINT_SECRET")" ;;
    second-host) ENDPOINT_SECRET="$(jq '.data.DB_HOST2 = "b2xkLmludmFsaWQ="' <<<"$ENDPOINT_SECRET")" ;;
    port) ENDPOINT_SECRET="$(jq '.data.DB_PORT = "NTQzMw=="' <<<"$ENDPOINT_SECRET")" ;;
    unavailable) DB_STATUS=stopped ;;
  esac
  if [[ "$1" == success ]]; then
    cutover verify-routing && expect_trace $'endpoint offline-restored\naws status\nkube endpoint'
  else
    reject cutover verify-routing
  fi
}
readonly_runner() {
  DR_DB_ACCESS='readonly'; ALLOW_SQL=1
  [[ "$1" != repair ]] || PRECHECK_FAILURES=1
  db_verify || return 1
  local expected=$'sql target\nx dr-secret-cutover.sh precheck'
  [[ "$1" != repair ]] || expected+=$'\nx dr-secret-cutover.sh fix-password\nx dr-secret-cutover.sh precheck'
  expect_trace "$expected"$'\nx dr-restore.sh validate-pg\nrun db-post psql\nrun counts dr-verify.sh'
}
readonly_connections() {
  DR_DB_ACCESS='readonly'; ALLOW_SQL=1
  connections && expect_trace $'x dr-fence-instance.sh wait-stopped offline-old\nrun connections dr-verify.sh'
}
readonly_capture() {
  DR_DB_ACCESS='readonly'; ALLOW_SQL=1; PSQL_OUTPUT=$'max_connections\t100'
  local captured
  captured="$(capture offline-old)" || return 1
  jq -e '.pgSettings.max_connections == "100"' "$captured" >/dev/null &&
    expect_trace $'aws instance\naws tags\nsql dr_dsn offline-old\nsql psql'
}
readonly_validate_pg() {
  DR_DB_ACCESS='readonly'; ALLOW_SQL=1; TARGET_DSN='host=offline.invalid'
  PSQL_OUTPUT=$'max_connections\t100'; BASE="$CASE_DIR/baseline.json"
  printf '%s\n' '{"pgSettings":{"max_connections":"100"},"capturedAt":"offline"}' > "$BASE"
  validate_pg && expect_trace 'sql psql'
}
readonly_master() {
  DR_DB_ACCESS='readonly'; ALLOW_SQL=1
  master_psql && expect_trace $'sql get-secret-value\nendpoint offline-old\nsql psql'
}
readonly_cutover() {
  DR_DB_ACCESS='readonly'; ALLOW_SQL=1
  cutover precheck && expect_trace $'endpoint offline-restored\nkube endpoint\nsql psql'
}
readonly_verify() {
  DR_DB_ACCESS='readonly'; ALLOW_SQL=1; PSQL_OUTPUT='in_recovery=false read_only_default=off'
  "$BASH" "$MIRROR/dr-verify.sh" db && expect_trace $'sql dr_dsn offline-restored\nsql psql'
}

prepare_kubectl() {
  [[ "${1:-}" == --context && "${2:-}" == dr-local ]] \
    || { forbidden 'prepare unpinned kubectl'; return 97; }
  shift 2
  if [[ "$*" == 'config view --raw -o json' ]]; then
    [[ "$KUBECONFIG" == "$PREP_STATE/kubeconfig" ]] || return 98
    trace 'prepare config'
    printf '%s\n' '{"clusters":[{"name":"offline-cluster","cluster":{"server":"https://offline.invalid","certificate-authority-data":"Zml4dHVyZQ=="}}],"users":[{"name":"offline-admin","user":{"token":"offline-admin-token"}}],"contexts":[{"name":"dr-local","context":{"cluster":"offline-cluster","user":"offline-admin"}}]}'
  elif [[ "$*" == '-n app create token dr-operator --duration=4h' ]]; then
    [[ "$KUBECONFIG" == "$PREP_STATE/kubeconfig" ]] || return 98
    trace 'prepare token duration=4h'
    printf '%s\n' "$PREP_TOKEN"
  elif [[ "${1:-} ${2:-} ${3:-} ${4:-}" == '-n app auth can-i' && $# == 6 ]]; then
    [[ "$KUBECONFIG" == "$PREP_STATE/operator-kubeconfig" ]] || return 98
    "$REAL_JQ" -e --arg token "$PREP_TOKEN" \
      '.users == [{name:"dr-operator",user:{token:$token}}] and .contexts[0].context.user == "dr-operator"' \
      "$KUBECONFIG" >/dev/null || return 98
    local operation="${5} ${6}"
    trace "prepare auth $operation"
    if [[ "$operation" == "$PREP_UNSAFE_OPERATION" ]]; then
      case "$PREP_REPLY" in
        yes) printf '%s\n' yes; return 0 ;;
        error) printf '%s\n' 'authorization unavailable'; return 1 ;;
        empty-error) printf '%s\n' 'offline authorization error' >&2; return 1 ;;
      esac
    fi
    if [[ "$operation" == 'get secrets/app-db-endpoint' ]]; then
      printf '%s\n' yes
    else
      case "$operation" in
        'get secrets/app-db-direct'|'get secrets/app-db-credentials'|'list secrets'|'create pods/exec'|'patch deployments'|'create pods')
          printf '%s\n' no; return 1 ;;
        *) forbidden "prepare auth $operation"; return 98 ;;
      esac
    fi
  else
    forbidden "prepare kubectl $*"; return 98
  fi
}
prepare_operator() {
  local variant="$1" operation="${2:-}" result=0
  export REAL_JQ PREP_STATE="$CASE_DIR/state" PREP_TOKEN=offline-operator-token-not-for-output
  export PREP_UNSAFE_OPERATION="$operation" PREP_REPLY="$variant"
  mkdir -p "$PREP_STATE" "$CASE_DIR/bin" || return 1
  local fixture_env=local fixture_profile=dr-local fixture_account=000000000000 fixture_context=dr-local
  case "$variant" in
    bad-env) fixture_env=uat ;;
    bad-profile) fixture_profile=offline-other ;;
    bad-account) fixture_account=invalid-fixture-account ;;
    bad-context) fixture_context=offline-other ;;
  esac
  printf 'export DR_ENV=%q AWS_PROFILE=%q ACCOUNT_ID=%q EKS_CONTEXT=%q\n' \
    "$fixture_env" "$fixture_profile" "$fixture_account" "$fixture_context" > "$PREP_STATE/local.env"
  : > "$PREP_STATE/kubeconfig"
  [[ "$(sed -n '\|^STATE=/workspace/tests/local/\.state$|p' "$ROOT/iac/local/prepare-operator.sh")" == \
    STATE=/workspace/tests/local/.state ]] || return 1
  sed "s|^STATE=/workspace/tests/local/\.state$|STATE=$PREP_STATE|" \
    "$ROOT/iac/local/prepare-operator.sh" > "$CASE_DIR/prepare-operator.sh"
  {
    printf '#!/usr/bin/env bash\n'
    declare -f trace forbidden prepare_kubectl
    printf 'prepare_kubectl "$@"\n'
  } > "$CASE_DIR/bin/kubectl"
  printf '#!/usr/bin/env bash\nexec "$REAL_JQ" "$@"\n' > "$CASE_DIR/bin/jq"
  chmod +x "$CASE_DIR/bin/kubectl" "$CASE_DIR/bin/jq"
  PATH="$CASE_DIR/bin:$PATH" "$BASH" "$CASE_DIR/prepare-operator.sh" \
    > "$CASE_DIR/prepare-output" 2>&1 || result=$?
  if grep -F -e "$PREP_TOKEN" -e offline-admin-token "$CASE_DIR/prepare-output" "$CALLS" >/dev/null; then
    echo 'Token leaked into output or command trace'; return 1
  fi
  if [[ "$variant" == bad-* ]]; then
    [[ "$result" == 2 && ! -e "$PREP_STATE/operator-kubeconfig" ]] && expect_trace '' &&
      grep -Fx 'REFUSED: isolated local fixture required.' "$CASE_DIR/prepare-output" >/dev/null
    return $?
  fi
  [[ -f "$PREP_STATE/operator-kubeconfig" ]] || return 1
  [[ "$(find "$PREP_STATE/operator-kubeconfig" -perm 0600 -print)" == "$PREP_STATE/operator-kubeconfig" ]] || return 1
  "$REAL_JQ" -e --arg token "$PREP_TOKEN" '
    .apiVersion == "v1" and .kind == "Config" and
    .clusters == [{name:"offline-cluster",cluster:{server:"https://offline.invalid","certificate-authority-data":"Zml4dHVyZQ=="}}] and
    .users == [{name:"dr-operator",user:{token:$token}}] and
    .contexts == [{name:"dr-local",context:{cluster:"offline-cluster",user:"dr-operator",namespace:"app"}}] and
    .["current-context"] == "" and ([.. | strings | select(contains("admin"))] | length == 0)
  ' "$PREP_STATE/operator-kubeconfig" >/dev/null || return 1
  if [[ "$variant" == success ]]; then
    [[ "$result" == 0 ]] || return 1
    expect_trace $'prepare config\nprepare token duration=4h\nprepare auth get secrets/app-db-endpoint\nprepare auth get secrets/app-db-direct\nprepare auth get secrets/app-db-credentials\nprepare auth list secrets\nprepare auth create pods/exec\nprepare auth patch deployments\nprepare auth create pods' &&
      grep -Fx 'Local operator kubeconfig prepared (4-hour token); credential Secret reads, pod exec and workload mutation denied.' \
        "$CASE_DIR/prepare-output" >/dev/null
  else
    [[ "$result" == 2 ]] && grep -Fx "prepare auth $operation" "$CALLS" >/dev/null &&
      grep -F 'REFUSED:' "$CASE_DIR/prepare-output" >/dev/null &&
      ! grep -F 'Local operator kubeconfig prepared' "$CASE_DIR/prepare-output" >/dev/null
  fi
}

identity_kubectl() {
  [[ "$*" == "--context $EKS_CONTEXT auth whoami -o json" ]] \
    || { forbidden "identity kubectl $*"; return 98; }
  trace 'identity whoami'
  printf '%s\n' "$IDENTITY_JSON"
  return "$IDENTITY_RC"
}
operator_identity() {
  local variant="$1" result=0 block
  export IDENTITY_JSON='{"status":{"userInfo":{"username":"system:serviceaccount:app:dr-operator"}}}' IDENTITY_RC=0
  case "$variant" in
    admin) IDENTITY_JSON='{"status":{"userInfo":{"username":"kubernetes-admin"}}}' ;;
    wrong-namespace) IDENTITY_JSON='{"status":{"userInfo":{"username":"system:serviceaccount:other:dr-operator"}}}' ;;
    missing) IDENTITY_JSON='{}' ;;
    auth-error) IDENTITY_JSON='{}'; IDENTITY_RC=1 ;;
  esac
  block="$(sed -n '/^  identity=/,/platform\/admin identity/p' "$ROOT/iac/local/dr.sh")"
  [[ "$block" == *'system:serviceaccount:app:dr-operator'* ]] || return 1
  {
    printf 'set -euo pipefail\n'
    declare -f trace forbidden identity_kubectl
    printf 'kubectl() { identity_kubectl "$@"; }\n%s\ntrace identity-accepted\n' "$block"
  } > "$CASE_DIR/identity.sh"
  "$BASH" "$CASE_DIR/identity.sh" > "$CASE_DIR/identity-output" 2>&1 || result=$?
  if [[ "$variant" == success ]]; then
    [[ "$result" == 0 ]] && expect_trace $'identity whoami\nidentity-accepted'
  else
    (( result != 0 )) && expect_trace 'identity whoami'
  fi
}
failback_owner_gate() {
  local variant="$1" result=0 block
  export app_owner=offline-owner app_destination_confirmed=yes app_evidence=offline-business-reference app_decision=GO
  case "$variant" in
    whitespace-owner) app_owner=$' \t ' ;;
    decision-owner) app_owner=GO ;;
    confirmed-short) app_destination_confirmed=Y ;;
    declined-destination) app_destination_confirmed=no ;;
    blank-confirmation) app_destination_confirmed='' ;;
    invalid-confirmation) app_destination_confirmed=offline-restored ;;
    whitespace-evidence) app_evidence=$' \t ' ;;
    no-go) app_decision=NO ;;
    missing-go) app_decision='' ;;
  esac
  block="$(sed -n '/^    \[\[ "${app_destination_confirmed,,}"/,/^    dr_mark T9 /p' "$ROOT/iac/local/dr.sh" | sed '/^    read -r -p /d')"
  [[ "$block" == *'app_decision'* && "$block" == *'dr_mark T9 '* ]] || return 1
  mkdir -p "$CASE_DIR/automation/scripts" || return 1
  local script_name
  for script_name in dr-secret-cutover.sh dr-eks-rollout.sh; do
    {
      printf '#!/usr/bin/env bash\n'
      declare -f trace forbidden
      printf '[[ "$*" == %q ]] || { forbidden "unexpected failback child $*"; exit 98; }\n' \
        "$(if [[ "$script_name" == dr-secret-cutover.sh ]]; then printf verify-routing; else printf check; fi)"
      printf 'trace %q\n' "failback $script_name"
    } > "$CASE_DIR/automation/scripts/$script_name"
    chmod +x "$CASE_DIR/automation/scripts/$script_name"
  done
  {
    printf 'set -euo pipefail\n'
    declare -f trace dr_mark
    printf '%s\n' "$block"
  } > "$CASE_DIR/failback-gate.sh"
  (cd "$CASE_DIR" && "$BASH" "$CASE_DIR/failback-gate.sh") > "$CASE_DIR/failback-output" 2>&1 || result=$?
  if [[ "$variant" == success || "$variant" == confirmed-short ]]; then
    [[ "$result" == 0 ]] &&
      expect_trace $'failback dr-secret-cutover.sh\nfailback dr-eks-rollout.sh\nmark T9' &&
      "$REAL_JQ" -en --rawfile receipt "$CASE_DIR/approvals/app-owner-e2e.txt" \
        '$receipt | contains("owner: offline-owner\ntarget: offline-restored\nevidence: offline-business-reference\nanswer: GO\noperator_sql: none\n")' >/dev/null
  else
    [[ "$result" == 2 && ! -e "$CASE_DIR/approvals/app-owner-e2e.txt" ]] &&
      no_marker T9 && expect_trace ''
  fi
}

for identity_variant in success admin wrong-namespace missing auth-error; do
  test_case "extracted local operator identity guard: $identity_variant" operator_identity "$identity_variant"
done
for failback_variant in success confirmed-short whitespace-owner decision-owner declined-destination blank-confirmation invalid-confirmation whitespace-evidence no-go missing-go; do
  test_case "extracted failback app-owner gate prevents premature T9: $failback_variant" failback_owner_gate "$failback_variant"
done
test_case 'actual prepare-operator creates private restricted kubeconfig with silent 4h token' prepare_operator success
for fixture_variant in bad-env bad-profile bad-account bad-context; do
  test_case "actual prepare-operator refuses fixture identity: $fixture_variant" prepare_operator "$fixture_variant"
done
for unsafe_operation in 'get secrets/app-db-direct' 'get secrets/app-db-credentials' 'list secrets' 'create pods/exec' 'patch deployments' 'create pods'; do
  for auth_reply in yes error empty-error; do
    test_case "actual prepare-operator refuses $unsafe_operation: $auth_reply" prepare_operator "$auth_reply" "$unsafe_operation"
  done
done

for secret_mode in k8s eso; do
  test_case "dr_app_secret refuses $secret_mode before any Secret fetch" secret_refused "$secret_mode"
done
test_case '_dr_pgpass_add refuses before creating .pgpass or its directory' cache_refused
test_case 'validate_pg refuses before DSN lookup or psql' sql_guard validate_pg
test_case 'master_psql refuses before fetching master credentials' sql_guard master_psql
test_case 'standalone SQL fence refuses without FENCE or readonly receipt' fence_refused
test_case 'runner refuses FENCE=quarantine in none before any mutation' quarantine_refused
for verify_command in db connections compare-counts wait-promoted unknown; do
  test_case "standalone dr-verify refuses $verify_command before SQL" script_refused dr-verify.sh "$verify_command"
done
test_case 'db_verify performs only API validate and records API-only evidence' verify_db
test_case 'db_verify settings-only also avoids SQL and target credentials' verify_db settings-only
test_case 'db_verify API validation failure cannot mark verified' verify_db_failure
for fence_mode in stop quarantine; do
  test_case "connections $fence_mode uses isolation, routing and rollout only" runner_connections "$fence_mode"
done
for failure_slice in isolation routing rollout; do
  test_case "connections rejects $failure_slice failure" connections_failure "$failure_slice"
done
for e2e_variant in success confirmed-yes confirmed-short declined-destination blank-confirmation invalid-confirmation missing-owner empty-owner whitespace-owner wrong-owner wrong-destination missing-destination missing-reference empty-reference whitespace-reference denied no-approval routing rollout isolation; do
  test_case "E2E owner gate and T9 contract: $e2e_variant" owner_e2e "$e2e_variant"
done
test_case 'resume retains pinned none mode from saved source file' resume_mode none none 0
test_case 'resume retains pinned readonly mode from saved source file' resume_mode readonly readonly 0
test_case 'resume refuses saved readonly into requested none' resume_mode none readonly 2
test_case 'resume refuses saved none into requested readonly' resume_mode readonly none 2
test_case 'resume refuses legacy source without explicit operator mode' resume_mode none legacy 2
for inventory_variant in success denied empty; do
  test_case "actual consumer check with temporary mocks: $inventory_variant" consumer_inventory "$inventory_variant"
done
test_case 'baseline capture none never calls dr_dsn or psql' baseline_capture
for forbidden_command in precheck fix-password; do
  test_case "standalone cutover refuses $forbidden_command before credentials" script_refused dr-secret-cutover.sh "$forbidden_command"
done
for mode_variant in eso ro; do
  test_case "operator cutover refuses $mode_variant" cutover_mode "$mode_variant"
done
for shape_variant in mixed extra-key missing-key empty-host credential-key duplicate-key; do
  test_case "operator apply rejects endpoint Secret shape: $shape_variant" cutover_shape "$shape_variant"
done
test_case 'operator apply checks API target, then endpoint update and rollout without SQL' apply_endpoint
for target_variant in unavailable api-failure invalid-port no-host endpoint-failure; do
  test_case "apply rejects target: $target_variant" target_rejected apply "$target_variant"
done
test_case 'apply rejects original DB and requires explicit failback' target_rejected apply original
for routing_variant in success first-host second-host port unavailable; do
  test_case "verify-routing checks every host, port and availability: $routing_variant" routing_check "$routing_variant"
done
test_case 'readonly db_verify retains precheck, validate-pg, SQL and counts' readonly_runner normal
test_case 'readonly db_verify retains failed login password-repair path' readonly_runner repair
test_case 'readonly connections retains dr_run sessions path' readonly_connections
test_case 'readonly baseline retains dr_dsn and pg_settings capture' readonly_capture
test_case 'readonly validate_pg retains SQL settings comparison' readonly_validate_pg
test_case 'readonly master_psql retains master Secret and SQL path' readonly_master
test_case 'readonly cutover precheck retains SQL path' readonly_cutover
test_case 'readonly dr-verify db retains SQL path' readonly_verify
printf '\nTests: %s; passed: %s; failed: %s\n' "$((PASSN + FAILN))" "$PASSN" "$FAILN"
(( FAILN == 0 ))