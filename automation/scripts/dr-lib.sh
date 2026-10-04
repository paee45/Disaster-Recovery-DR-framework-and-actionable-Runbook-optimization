#!/usr/bin/env bash
# dr-lib.sh — shared helpers for DR runbooks. Source it, do not execute it.
#   source automation/scripts/dr-lib.sh && dr_init
# Requires: aws cli v2, jq, psql, kubectl. All timestamps are UTC ISO-8601.

: "${DR_ID:?set DR_ID (see runbook env block)}"
: "${DR_REGION:?set DR_REGION}"
: "${DR_DB:?set DR_DB}"

DR_EVIDENCE_DIR="${DR_EVIDENCE_DIR:-$(pwd)/evidence/${DR_ID}}"
DR_TIMELINE="${DR_EVIDENCE_DIR}/timeline.jsonl"

_dr_now() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ; }
_dr_actor() { aws sts get-caller-identity --query Arn --output text 2>/dev/null || echo "unknown"; }

# dr_init — create evidence dirs, record start, export DR_DSN for the DR instance endpoint.
dr_init() {
  mkdir -p "${DR_EVIDENCE_DIR}"/{approvals,db,aws,k8s,app,comms}
  DR_ACTOR="$(_dr_actor)"; export DR_ACTOR
  dr_mark RUNBOOK_START "runbook=RB-DR-RDS-001 git=$(git rev-parse --short HEAD 2>/dev/null || echo n/a) mode=${DR_MODE:-unplanned}"
  dr_set_dsn
}

# dr_mark <marker> [note] [--at <iso-ts>] — append a timeline event (T0..T10, step ids, decisions).
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
        --arg note "$note" --arg actor "${DR_ACTOR:-unknown}" --arg env "${DR_ENV:-unknown}" --arg id "$DR_ID" \
        '{ts:$ts, recorded_at:$recorded, marker:$m, note:$note, actor:$actor, env:$env, dr_id:$id}' \
    >> "${DR_TIMELINE}"
  echo "[timeline] ${at:-$(_dr_now)} ${marker} ${note}"
}

# dr_run <name> <cmd...> — run a command, tee stdout+stderr into evidence, mark start/end + exit code.
dr_run() {
  local name="$1"; shift
  local out="${DR_EVIDENCE_DIR}/${name}.txt"
  dr_mark "RUN_START:${name}" "$*"
  { echo "# $(_dr_now) \$ $*"; "$@"; } 2>&1 | tee "${out}"
  local rc=${PIPESTATUS[0]}
  dr_mark "RUN_END:${name}" "rc=${rc}"
  return "${rc}"
}

# dr_set_dsn — build libpq conninfo for the DR *instance* endpoint (not the CNAME, which may still point to Region A).
dr_set_dsn() {
  local endpoint secret
  endpoint="$(aws rds describe-db-instances --region "$DR_REGION" --db-instance-identifier "$DR_DB" \
              --query 'DBInstances[0].Endpoint.Address' --output text)"
  secret="$(aws secretsmanager get-secret-value --region "$DR_REGION" --secret-id "${SECRET_ID}" \
              --query SecretString --output text)"
  PGUSER="$(jq -r .username <<<"$secret")"; PGPASSWORD="$(jq -r .password <<<"$secret")"
  export PGUSER PGPASSWORD
  export DR_DSN="host=${endpoint} port=5432 dbname=${DB_NAME:-app} sslmode=verify-full sslrootcert=${PGSSLROOTCERT:-$HOME/.postgresql/global-bundle.pem} connect_timeout=5 application_name=dr-runbook"
}
