#!/usr/bin/env bash
# dr-lib.sh — shared helpers for all RDS DR runbooks. Source it, do not execute it.
#   source env/<env>.env && source automation/scripts/dr-lib.sh && dr_init <SCENARIO>
#   dr_set_target <db-instance-id>      # the instance that is / becomes the primary
# Requires: aws cli, jq, psql, kubectl. All timestamps are UTC ISO-8601.
# Every script calls dr_guard first: wrong AWS account or wrong cluster → stop before doing anything.

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
if [[ -n "${AWS_ACCESS_KEY_ID:-}${AWS_SESSION_TOKEN:-}" ]]; then
  echo "WARN: AWS_ACCESS_KEY_ID/AWS_SESSION_TOKEN are set in the shell; they are ignored by these scripts (profile ${AWS_PROFILE} is used)." >&2
fi
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_DEFAULT_PROFILE
export AWS_DEFAULT_REGION="$AWS_REGION" AWS_PAGER=""

aws() {
  local pin=()
  [[ " $* " == *" --profile "* || " $* " == *" --profile="* ]] || pin+=(--profile "$AWS_PROFILE")
  [[ " $* " == *" --region "*  || " $* " == *" --region="*  ]] || pin+=(--region "$AWS_REGION")
  command aws "${pin[@]}" "$@"
}
kubectl() {
  if [[ " $* " == *" --context "* || " $* " == *" --context="* ]]; then command kubectl "$@"
  else command kubectl --context "$EKS_CONTEXT" "$@"; fi
}
export -f aws kubectl

_dr_die() { echo "GUARD FAIL: $*" >&2; return 1; }

# dr_guard — verify we are pointed at the intended account + cluster. Cached per (env, profile, context, account).
dr_guard() {
  local key="${DR_ENV}|${AWS_PROFILE}|${AWS_REGION}|${EKS_CONTEXT}|${ACCOUNT_ID:-}"
  [[ "${DR_GUARD_OK:-}" == "$key" ]] && return 0
  : "${ACCOUNT_ID:?ACCOUNT_ID must be set in env/<env>.env}"
  local acct arn server want_server cm_env cm_acct
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
_dr_actor() { aws sts get-caller-identity --query Arn --output text 2>/dev/null || echo "unknown"; }

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
  aws rds describe-db-instances --db-instance-identifier "$1" \
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
  secret="$(aws secretsmanager get-secret-value --secret-id "${SECRET_ID}" --query SecretString --output text)" || return 1
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
