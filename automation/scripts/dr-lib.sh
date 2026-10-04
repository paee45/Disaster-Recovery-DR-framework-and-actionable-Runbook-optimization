#!/usr/bin/env bash
# dr-lib.sh — shared helpers for all RDS DR runbooks. Source it, do not execute it.
#   source env/<env>.env && source automation/scripts/dr-lib.sh && dr_init <SCENARIO>
#   dr_set_target <db-instance-id>      # the instance that is / becomes the primary
# Requires: aws cli v2, jq, psql, kubectl. All timestamps are UTC ISO-8601.

: "${DR_ENV:?source env/<env>.env first}"
: "${SECRET_ID:?SECRET_ID missing in env profile}"

_dr_now() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ; }
_dr_actor() { aws sts get-caller-identity --query Arn --output text 2>/dev/null || echo "unknown"; }

# dr_init <scenario> — S1|S2|S3|S4|FB-S1|FB-S2|FB-S3S4. Creates the evidence dir and starts the timeline.
dr_init() {
  export DR_SCENARIO="${1:?scenario, e.g. S2}"
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
  aws rds describe-db-instances --db-instance-identifier "$1" \
    --query 'DBInstances[0].[Endpoint.Address,Endpoint.Port]' --output text 2>/dev/null
}

# dr_dsn <db-id> — libpq conninfo for an instance endpoint using the APP credentials from $SECRET_ID.
dr_dsn() {
  local addr port secret
  read -r addr port <<<"$(dr_endpoint "$1")"
  [[ -z "$addr" || "$addr" == "None" ]] && return 1
  secret="$(aws secretsmanager get-secret-value --secret-id "${SECRET_ID}" --query SecretString --output text)"
  PGUSER="$(jq -r .username <<<"$secret")"; PGPASSWORD="$(jq -r .password <<<"$secret")"
  export PGUSER PGPASSWORD
  echo "host=${addr} port=${port:-5432} dbname=${DB_NAME:-app} sslmode=verify-full sslrootcert=${PGSSLROOTCERT:-$HOME/.postgresql/global-bundle.pem} connect_timeout=5 application_name=dr-runbook"
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
