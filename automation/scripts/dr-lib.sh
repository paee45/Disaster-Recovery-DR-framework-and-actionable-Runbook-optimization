#!/usr/bin/env bash
# dr-lib.sh — shared helpers for all RDS DR runbooks. Source it, do not execute it.
#   source env/<env>.env && source automation/scripts/dr-lib.sh && dr_init <SCENARIO>
#   dr_set_target <db-instance-id>      # the instance that is / becomes the primary
# Requires: aws cli, jq, psql, kubectl. All timestamps are UTC ISO-8601.
# Every script calls dr_guard first: wrong AWS account or wrong cluster → stop before doing anything.

# macOS: the scripts need bash >= 4 and GNU date/sha256sum (brew install bash coreutils jq libpq awscli kubectl).
if [[ "$(uname -s)" == Darwin ]]; then
  for _d in /opt/homebrew/opt/coreutils/libexec/gnubin /usr/local/opt/coreutils/libexec/gnubin /opt/homebrew/opt/libpq/bin /usr/local/opt/libpq/bin; do
    [[ -d "$_d" && ":$PATH:" != *":$_d:"* ]] && PATH="$_d:$PATH"
  done; export PATH
fi
if (( BASH_VERSINFO[0] < 4 )) || ! date -u -d '2020-01-01T00:00:00Z' +%s >/dev/null 2>&1 || ! command -v sha256sum >/dev/null; then
  echo "ERROR: need bash>=4 + GNU coreutils (macOS: brew install bash coreutils; run with the brew bash)" >&2; return 1 2>/dev/null || exit 1
fi

: "${DR_ENV:?source env/<env>.env first}"
: "${SECRET_ID:?SECRET_ID missing in env profile}"

# ─────────────────────────── Safety guardrails (wrong account / wrong cluster) ───────────────────────────
# 1. Every `aws` call is pinned to $AWS_PROFILE + $AWS_REGION; every `kubectl` call to $EKS_CONTEXT.
#    The wrappers are exported, so scripts started from this shell inherit them too.
# 2. dr_guard proves the identity BEFORE any action: AWS account == $ACCOUNT_ID, kube context exists,
#    cluster identity ConfigMap (kube-system/dr-cluster-identity) says env=$DR_ENV + account=$ACCOUNT_ID,
#    and (EKS) the context's API server == the EKS endpoint of $EKS_CLUSTER_NAME in that account.
# 3. dr_confirm asks for a typed confirmation before PROD changes (DR_ASSUME_YES=1 skips it for automation).
: "${AWS_PROFILE:?AWS_PROFILE must be set in env/<env>.env — never rely on default credentials}"
: "${AWS_REGION:?AWS_REGION must be set in env/<env>.env}"
: "${EKS_CONTEXT:?EKS_CONTEXT must be set in env/<env>.env}"
# 4. STRICT PINNING (default, DR_STRICT_PIN=1): every aws call must carry --profile $AWS_PROFILE and --region, every
#    kubectl call --context $EKS_CONTEXT, written on the command itself. A missing flag is REFUSED (exit 97), never
#    filled in. A flag naming ANOTHER profile/context is refused in every mode. DR_STRICT_PIN=0 (manual convenience)
#    fills missing flags from the env file instead; the guard still verifies account + cluster.
#    No defaults: static keys in the environment, a [default] AWS profile, a kube current-context, or contexts of other
#    environments in this env's kubeconfig fail dr_guard (see docs/12). Every call is audit-logged (commands.jsonl).
DR_STRICT_PIN="${DR_STRICT_PIN:-1}"; export DR_STRICT_PIN
if [[ -n "${AWS_ACCESS_KEY_ID:-}${AWS_SECRET_ACCESS_KEY:-}${AWS_SESSION_TOKEN:-}" ]]; then
  if [[ "$DR_STRICT_PIN" == 1 ]]; then
    echo "REFUSED: AWS_ACCESS_KEY_ID/AWS_SESSION_TOKEN are set in this shell — static/exported keys can point at any account. unset them (use the SSO profile $AWS_PROFILE)." >&2
    return 97 2>/dev/null || exit 97
  fi
  echo "WARN: AWS_ACCESS_KEY_ID/AWS_SESSION_TOKEN are set in the shell; ignored (profile ${AWS_PROFILE} is used)." >&2
fi
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_DEFAULT_PROFILE
export AWS_DEFAULT_REGION="$AWS_REGION" AWS_PAGER=""

# _dr_flag <--flag> <args...> — value of "--flag X" / "--flag=X" (last one wins), empty if absent
_dr_flag() {
  local f="$1" v=""; shift
  while (( $# )); do
    case "$1" in "$f") v="${2-}"; shift ;; "$f="*) v="${1#*=}" ;; esac
    shift || true
  done
  printf '%s' "$v"
}
_dr_refuse() { echo "REFUSED $1: $2" >&2; echo "         command: $3" >&2; _dr_audit_line "$1" 97 0 "REFUSED" "${@:4}"; return 97; }
# audit trail of every aws/kubectl call made through the wrappers (args redacted, no output) → evidence
_dr_audit_line() { # tool rc ms status args...
  local log="${DR_AUDIT_LOG:-${DR_EVIDENCE_DIR:+$DR_EVIDENCE_DIR/commands.jsonl}}" tool="$1" rc="$2" ms="$3" st="$4" a qargs=() red=0
  [[ -n "$log" ]] || return 0
  shift 4
  for a in "$@"; do
    if (( red )); then qargs+=("***"); red=0; continue; fi
    case "$a" in
      --secret-string|--secret-binary|--master-user-password|--password|--token) qargs+=("$a"); red=1 ;;
      --secret-string=*|--master-user-password=*|--password=*|--token=*) qargs+=("${a%%=*}=***") ;;
      --from-literal=*) a="${a#--from-literal=}"; qargs+=("--from-literal=${a%%=*}=***") ;;
      *) qargs+=("$a") ;;
    esac
  done
  mkdir -p "$(dirname "$log")" 2>/dev/null || return 0
  jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" --arg tool "$tool" --argjson rc "$rc" --argjson ms "$ms" --arg st "$st" \
     --arg env "${DR_ENV:-}" --arg id "${DR_ID:-}" --arg caller "${0##*/}" --arg actor "${DR_ACTOR:-}" \
     '{ts:$ts, tool:$tool, status:$st, rc:$rc, ms:$ms, env:$env, dr_id:$id, script:$caller, actor:$actor, args:$ARGS.positional}' \
     --args -- "${qargs[@]}" >> "$log" 2>/dev/null || true
}
_dr_exec() { # tool args... — run the real binary, keep its rc, audit it
  local tool="$1" t0 rc=0; shift; t0=$(date +%s%3N)
  if [[ "$tool" == aws ]]; then ( unset AWS_PROFILE AWS_DEFAULT_PROFILE; command aws "$@" ) || rc=$?   # pin-lint: ok (the wrapper itself; flags verified above)
  else command kubectl "$@" || rc=$?; fi
  _dr_audit_line "$tool" "$rc" $(( $(date +%s%3N) - t0 )) "$([[ $rc == 0 ]] && echo ok || echo error)" "$@"
  return "$rc"
}
aws() {
  local p r pin=(); p="$(_dr_flag --profile "$@")"; r="$(_dr_flag --region "$@")"
  [[ -z "$p" || "$p" == "$AWS_PROFILE" ]] || { _dr_refuse aws "--profile '$p' is not this env's profile '$AWS_PROFILE' (DR_ENV=$DR_ENV)" "aws $*" "$@"; return 97; }
  if [[ "$DR_STRICT_PIN" == 1 ]]; then
    [[ -n "$p" ]] || { _dr_refuse aws "--profile \"\$AWS_PROFILE\" missing on the command (strict pinning)" "aws $*" "$@"; return 97; }
    [[ -n "$r" ]] || { _dr_refuse aws "--region missing on the command (strict pinning)" "aws $*" "$@"; return 97; }
  fi
  [[ -n "$p" ]] || pin+=(--profile "$AWS_PROFILE")
  [[ -n "$r" ]] || pin+=(--region "$AWS_REGION")
  _dr_exec aws "${pin[@]}" "$@"
}
kubectl() {
  local c; c="$(_dr_flag --context "$@")"
  [[ -z "$c" || "$c" == "$EKS_CONTEXT" ]] || { _dr_refuse kubectl "--context '$c' is not this env's context '$EKS_CONTEXT' (DR_ENV=$DR_ENV)" "kubectl $*" "$@"; return 97; }
  if [[ -z "$c" ]]; then
    if [[ "${1:-}" == config || "${1:-} ${2:-}" == "version --client" ]]; then _dr_exec kubectl "$@"; return; fi   # local file ops only
    [[ "$DR_STRICT_PIN" == 1 ]] && { _dr_refuse kubectl "--context \"\$EKS_CONTEXT\" missing on the command (strict pinning)" "kubectl $*" "$@"; return 97; }
    _dr_exec kubectl --context "$EKS_CONTEXT" "$@"; return
  fi
  _dr_exec kubectl "$@"
}
export -f aws kubectl _dr_flag _dr_refuse _dr_audit_line _dr_exec

_dr_die() { echo "GUARD FAIL: $*" >&2; return 1; }

# dr_guard — verify we are pointed at the intended account + cluster. Cached per (env, profile, context, account).
dr_guard() {
  local key="${DR_ENV}|${AWS_PROFILE}|${AWS_REGION}|${EKS_CONTEXT}|${ACCOUNT_ID:-}|${KUBECONFIG:-}|${DR_STRICT_PIN}"
  [[ "${DR_GUARD_OK:-}" == "$key" ]] && return 0
  : "${ACCOUNT_ID:?ACCOUNT_ID must be set in env/<env>.env}"
  local acct arn server want_server cm_env cm_acct cfg cred kcfg other
  read -r acct arn <<<"$(command aws --profile "$AWS_PROFILE" --region "$AWS_REGION" sts get-caller-identity --query '[Account,Arn]' --output text 2>/dev/null)"
  [[ "$acct" == "$ACCOUNT_ID" ]] || { _dr_die "AWS profile '$AWS_PROFILE' is account '${acct:-<no credentials>}', expected $ACCOUNT_ID (env $DR_ENV)"; return 1; }
  if [[ -n "${AWS_ROLE_PATTERN:-}" && ! "$arn" =~ $AWS_ROLE_PATTERN ]]; then _dr_die "caller $arn does not match AWS_ROLE_PATTERN '$AWS_ROLE_PATTERN'"; return 1; fi
  server="$(command kubectl config view -o jsonpath="{.clusters[?(@.name==\"$(command kubectl config view -o jsonpath="{.contexts[?(@.name==\"$EKS_CONTEXT\")].context.cluster}")\")].cluster.server}" 2>/dev/null)"
  [[ -n "$server" ]] || { _dr_die "kube context '$EKS_CONTEXT' not found in ${KUBECONFIG:-~/.kube/config}"; return 1; }
  if [[ -n "${EKS_CLUSTER_NAME:-}" ]]; then
    want_server="$(command aws --profile "$AWS_PROFILE" --region "$AWS_REGION" eks describe-cluster --name "$EKS_CLUSTER_NAME" --query cluster.endpoint --output text 2>/dev/null)"
    [[ "$server" == "$want_server" ]] || { _dr_die "context '$EKS_CONTEXT' → $server, but EKS cluster $EKS_CLUSTER_NAME in $ACCOUNT_ID is ${want_server:-<not found>}"; return 1; }
  fi
  if [[ "${REQUIRE_CLUSTER_IDENTITY:-true}" == "true" ]]; then
    cm_env="$(command kubectl --context "$EKS_CONTEXT" --request-timeout=10s -n kube-system get configmap dr-cluster-identity -o jsonpath='{.data.env}' 2>/dev/null)"
    cm_acct="$(command kubectl --context "$EKS_CONTEXT" --request-timeout=10s -n kube-system get configmap dr-cluster-identity -o jsonpath='{.data.account}' 2>/dev/null)"
    [[ "$cm_env" == "$DR_ENV" && "$cm_acct" == "$ACCOUNT_ID" ]] || {
      _dr_die "cluster behind '$EKS_CONTEXT' identifies as env='${cm_env:-?}' account='${cm_acct:-?}', expected env=$DR_ENV account=$ACCOUNT_ID (kube-system/dr-cluster-identity)"; return 1; }
  fi
  if [[ -n "${DR_ENDPOINT_MAP:-}" && "$DR_ENV" != "local" ]]; then _dr_die "DR_ENDPOINT_MAP is a local-test seam and is refused in env '$DR_ENV'"; return 1; fi
  # --- no defaults (strict): a default can silently pick an account or cluster in a manual command
  cfg="${AWS_CONFIG_FILE:-$HOME/.aws/config}"; cred="${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}"
  if [[ "${DR_ALLOW_DEFAULT_PROFILE:-0}" != 1 ]] && grep -qsE '^\s*\[(default|profile default)\]' "$cfg" "$cred"; then
    _dr_die "a [default] AWS profile exists in $cfg / $cred — remove it (SSO named profiles only) or set DR_ALLOW_DEFAULT_PROFILE=1"; return 1; fi
  kcfg="${KUBECONFIG:-$HOME/.kube/config}"
  if [[ "${DR_ALLOW_CURRENT_CONTEXT:-0}" != 1 && -n "$(command kubectl config current-context 2>/dev/null)" ]]; then
    _dr_die "kubeconfig $kcfg has current-context '$(command kubectl config current-context)' — fix: kubectl config unset current-context (or DR_ALLOW_CURRENT_CONTEXT=1)"; return 1; fi
  other="$(command kubectl config get-contexts -o name 2>/dev/null | grep -E '^dr-(dev|uat|prod|local)$' | grep -vx "$EKS_CONTEXT" | tr '\n' ' ' || true)"
  if [[ -n "$other" && "${DR_ALLOW_FOREIGN_CONTEXTS:-0}" != 1 ]]; then
    _dr_die "kubeconfig $kcfg (env $DR_ENV) also holds context(s) of other environments: $other— use one kubeconfig per env"; return 1; fi
  export DR_GUARD_OK="$key"
  echo "GUARD OK: env=$DR_ENV account=$acct caller=$arn region=$AWS_REGION context=$EKS_CONTEXT ($server)" >&2
}

# dr_confirm "<action>" — typed confirmation for PROD changes (anti-accident, not an approval gate).
dr_confirm() {
  [[ "$DR_ENV" == "prod" && "${DR_ASSUME_YES:-0}" != "1" ]] || return 0
  local ans; read -r -p "PROD change: $1 — type 'prod' to continue: " ans </dev/tty
  [[ "$ans" == "prod" ]] || { echo "aborted" >&2; return 1; }
}

_dr_now() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ; }
_dr_actor() { aws --profile "$AWS_PROFILE" --region "$AWS_REGION" sts get-caller-identity --query Arn --output text 2>/dev/null || echo "unknown"; }

# dr_init <scenario> — S1|S2|S3|S4|FB-S1|FB-S2|FB-S3S4. Creates the evidence dir and starts the timeline.
dr_init() {
  export DR_SCENARIO="${1:?scenario, e.g. S2}"
  dr_guard || return 1
  export DR_ID="${DR_ID:-DR-$(date -u +%Y%m%d-%H%M)-${DR_ENV}-${DR_SCENARIO}}"
  export DR_EVIDENCE_DIR="${DR_EVIDENCE_DIR:-$(pwd)/evidence/${DR_ID}}"
  export DR_TIMELINE="${DR_EVIDENCE_DIR}/timeline.jsonl"
  mkdir -p "${DR_EVIDENCE_DIR}"/{approvals,db,aws,k8s,app,comms}
  DR_ACTOR="$(_dr_actor)"; export DR_ACTOR
  export OLD_DB="${OLD_DB:-$PRIMARY_DB}"
  dr_mark RUNBOOK_START "scenario=${DR_SCENARIO} env=${DR_ENV} git=$(git rev-parse --short HEAD 2>/dev/null || echo n/a) mode=${DR_MODE:-unplanned}"
  echo "DR_ID=${DR_ID}  evidence=${DR_EVIDENCE_DIR}"
  echo "ENV=${DR_ENV} PRIMARY_DB=${PRIMARY_DB:-} OLD_DB=${OLD_DB:-} REPLICA_DB=${REPLICA_DB:-} SECRET_ID=${SECRET_ID} EKS_CONTEXT=${EKS_CONTEXT:-} K8S_SECRET=${K8S_SECRET:-}/${K8S_HOST_KEY:-DB_HOST}"
  echo "All timestamps are UTC. Next: dr_set_target <instance> once the target exists."
}

# dr_mark <marker> [note...] [--at <iso-ts>] — append a timeline event (T0..T10, step ids, decisions).
dr_mark() {
  local marker="$1"; shift || true
  local note="" at=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --at) at="$2"; shift 2 ;;
      *) note="${note:+$note }$1"; shift ;;
    esac
  done
  jq -cn --arg ts "${at:-$(_dr_now)}" --arg recorded "$(_dr_now)" --arg m "$marker" \
        --arg note "$note" --arg actor "${DR_ACTOR:-unknown}" --arg env "${DR_ENV}" \
        --arg id "${DR_ID:-unset}" --arg sc "${DR_SCENARIO:-unset}" \
        '{ts:$ts, recorded_at:$recorded, marker:$m, note:$note, actor:$actor, env:$env, dr_id:$id, scenario:$sc}' \
    >> "${DR_TIMELINE:?run dr_init first}"
  echo "[timeline] ${at:-$(_dr_now)} ${marker} ${note}"
}

# dr_run <name> <cmd...> — run a command, tee output into evidence, mark start/end + exit code.
dr_run() {
  local name="$1"; shift
  local out="${DR_EVIDENCE_DIR}/${name}.txt"
  dr_mark "RUN_START:${name}" "$*"
  { echo "# $(_dr_now) \$ $*"; "$@"; } 2>&1 | tee "${out}"
  local rc=${PIPESTATUS[0]}
  dr_mark "RUN_END:${name}" "rc=${rc}"
  return "${rc}"
}

# dr_endpoint <db-id> — print "address port" of an instance (empty if it does not exist).
dr_endpoint() {
  if [[ -n "${DR_ENDPOINT_MAP:-}" && "$DR_ENV" == "local" ]]; then   # LOCAL TEST ONLY: map mock RDS ids to real Postgres
    local pat host port
    while read -r pat host port; do
      [[ -z "$pat" || "$pat" == \#* ]] && continue
      # shellcheck disable=SC2053
      [[ "$1" == $pat ]] && { echo "$host $port"; return 0; }
    done < "$DR_ENDPOINT_MAP"
  fi
  aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-instances --db-instance-identifier "$1" \
    --query 'DBInstances[0].[Endpoint.Address,Endpoint.Port]' --output text 2>/dev/null
}

# DB passwords never go on a command line or into a DSN: dr_dsn stores them in a private pgpass file (mode 600).
# (Exporting PGPASSWORD inside "$(dr_dsn …)" would be lost — command substitution runs in a subshell.)
export PGPASSFILE="${PGPASSFILE:-${XDG_RUNTIME_DIR:-$HOME/.cache}/dr-runbook/pgpass}"
_dr_pgpass_add() { # host port db user password
  local esc="${5//\\/\\\\}"; esc="${esc//:/\\:}"
  ( umask 077; mkdir -p "$(dirname "$PGPASSFILE")"; touch "$PGPASSFILE"
    grep -v "^$1:$2:$3:$4:" "$PGPASSFILE" > "$PGPASSFILE.tmp" || true
    printf '%s:%s:%s:%s:%s\n' "$1" "$2" "$3" "$4" "$esc" >> "$PGPASSFILE.tmp"; mv "$PGPASSFILE.tmp" "$PGPASSFILE" )
}

# dr_dsn <db-id> — libpq conninfo (no password) for an instance endpoint, with the APP credentials from $SECRET_ID.
dr_dsn() {
  local addr port secret user
  read -r addr port <<<"$(dr_endpoint "$1")"
  [[ -z "$addr" || "$addr" == "None" ]] && return 1
  secret="$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" secretsmanager get-secret-value --secret-id "${SECRET_ID}" --query SecretString --output text)" || return 1
  user="$(jq -r .username <<<"$secret")"
  _dr_pgpass_add "$addr" "${port:-5432}" "${DB_NAME:-app}" "$user" "$(jq -r .password <<<"$secret")"
  echo "host=${addr} port=${port:-5432} dbname=${DB_NAME:-app} user=${user} sslmode=${DR_PGSSLMODE:-verify-full} sslrootcert=${PGSSLROOTCERT:-$HOME/.postgresql/global-bundle.pem} connect_timeout=5 application_name=dr-runbook"
}

# dr_set_target <db-id> — export TARGET_DB/TARGET_DSN and (if reachable) OLD_DSN.
dr_set_target() {
  export TARGET_DB="${1:?db instance id}"
  TARGET_DSN="$(dr_dsn "$TARGET_DB")" || echo "WARN: $TARGET_DB not found yet (restore in progress?) — re-run dr_set_target when available"
  export TARGET_DSN
  if [[ -n "${OLD_DB:-}" && "$OLD_DB" != "$TARGET_DB" ]]; then
    OLD_DSN="$(dr_dsn "$OLD_DB" 2>/dev/null)" || OLD_DSN=""
    export OLD_DSN
  fi
  dr_mark TARGET_SET "target=${TARGET_DB} old=${OLD_DB:-none}"
}

# dr_phase <start|end> <name> [budget-min] — phase timer (TICKET-107). Prints elapsed vs budget, writes PHASE_* markers.
dr_phase() {
  local action="$1" name="$2" budget="${3:-}" var
  var="DR_PHASE_START_${name//[^A-Za-z0-9]/_}"
  if [[ "$action" == "start" ]]; then
    printf -v "$var" '%s' "$(date +%s)"; export "${var?}"
    dr_mark "PHASE_START:${name}" "budget_min=${budget:-n/a}"
  else
    local start="${!var:-$(date +%s)}" el
    el=$(( $(date +%s) - start ))
    dr_mark "PHASE_END:${name}" "elapsed_s=${el}"
    printf '⏱  phase %-28s %dm%02ds%s\n' "$name" $((el/60)) $((el%60)) "${budget:+ (budget ${budget}m)}"
    dr_sync_evidence
  fi
}

# dr_redact <file> — mask secrets in a text log in place (passwords, tokens, secret strings, PG/AWS keys)
dr_redact() {
  sed -E -i.bak \
    -e 's/("(password|Password|SecretString|secret|token|SessionToken|SecretAccessKey)"[[:space:]]*:[[:space:]]*")[^"]*"/\1***"/g' \
    -e 's/((PGPASSWORD|AWS_SECRET_ACCESS_KEY|AWS_SESSION_TOKEN|AWS_ACCESS_KEY_ID)=).*$/\1*** (rest of line redacted)/' \
    -e 's/(--(secret-string|master-user-password|password|token)[ =]).*$/\1*** (rest of line redacted)/' \
    -e "s/(PASSWORD[[:space:]]+')[^']*'/\1***'/Ig" \
    -e 's/(postgres(ql)?:\/\/[^:\/@[:space:]]+:)[^@[:space:]]+@/\1***@/g' "$1" && rm -f "$1.bak"
}

# dr_sync_evidence — copy the evidence folder to the WORM bucket NOW (best effort, incremental). Called at every
# dr_phase end, so evidence leaves the laptop during the event, not only at the end (dr-collect-evidence.sh).
dr_sync_evidence() {
  [[ -n "${DR_EVIDENCE_DIR:-}" && -n "${EVIDENCE_BUCKET:-}" && "${DR_EVIDENCE_SYNC:-1}" == 1 ]] || return 0
  local prefix; prefix="s3://${EVIDENCE_BUCKET}/${DR_ENV}/$(date -u +%Y)/${DR_ID}/"
  if aws --profile "$AWS_PROFILE" --region "$AWS_REGION" s3 sync "$DR_EVIDENCE_DIR/" "$prefix" --sse aws:kms --only-show-errors \
       --exclude 'terminal/*.raw' >/dev/null 2>&1; then
    echo "[evidence] synced → $prefix" >&2
  else
    echo "[evidence] WARN sync to $prefix failed (kept locally; dr-collect-evidence.sh uploads at the end)" >&2
  fi
}

# dr_summary — per-phase durations + elapsed since T0 (for the channel and the report).
dr_summary() {
  jq -rs '
    (map(select(.marker=="T0"))[0].ts // .[0].ts) as $t0
    | (map(select(.marker|startswith("PHASE_END:")))[] | "\(.marker|ltrimstr("PHASE_END:")): \(.note)"),
      "since T0: \(((now - ($t0|sub("\\.[0-9]+Z$";"Z")|fromdateiso8601))/60|floor)) min (target ${RTO_TARGET_MIN:-30})"
  ' "$DR_TIMELINE" | sed "s/\${RTO_TARGET_MIN:-30}/${RTO_TARGET_MIN:-30}/"
}
