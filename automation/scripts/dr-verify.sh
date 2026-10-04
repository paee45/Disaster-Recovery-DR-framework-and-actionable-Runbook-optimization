#!/usr/bin/env bash
# dr-verify.sh — verification helpers.
#   wait-promoted : block until TARGET_DB (promoted replica) is standalone + writable (S2 P2-S05/S06)
#   db            : writability probe on TARGET_DB
#   connections   : app sessions per application_name on TARGET_DB and OLD_DB (old must reach 0)
#   app           : deep-health URLs (APP_HEALTH_URLS)
#   compare-counts: row counts of VERIFY_TABLES on OLD vs TARGET
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=dr-lib.sh
source "$HERE/dr-lib.sh"
: "${TARGET_DB:?run dr_set_target first}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-1800}"

wait_promoted() {
  local deadline=$(( $(date +%s) + TIMEOUT_SECONDS )) dsn
  while (( $(date +%s) < deadline )); do
    read -r status source <<<"$(aws rds describe-db-instances --db-instance-identifier "$TARGET_DB" \
      --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier]' --output text)"
    echo "$(date -u +%FT%TZ) status=${status} source=${source}"
    # Pitfall: right after the API call the instance may still report 'available' WITH a source set.
    if [[ "$status" == "available" && ( "$source" == "None" || -z "$source" ) ]]; then
      dsn="$(dr_dsn "$TARGET_DB")"
      if [[ "$(psql "$dsn" -XAtqc 'select pg_is_in_recovery()' 2>/dev/null)" == "f" ]]; then
        echo "PROMOTED: standalone, not in recovery"; return 0
      fi
    fi
    sleep 15
  done
  echo "TIMEOUT waiting for promotion after ${TIMEOUT_SECONDS}s"; return 1
}

db_probe() {
  psql "$(dr_dsn "$TARGET_DB")" -XAtq -v ON_ERROR_STOP=1 <<'SQL'
select 'in_recovery=' || pg_is_in_recovery() || ' read_only_default=' || current_setting('default_transaction_read_only');
create schema if not exists dr;
create table if not exists dr.write_probe(id bigserial primary key, ts timestamptz default clock_timestamp(), note text);
insert into dr.write_probe(note) values ('dr-verify') returning 'write_probe_ok id=' || id || ' ts=' || ts;
SQL
}

sessions() { # sessions <db-id> <label>
  local dsn; dsn="$(dr_dsn "$1" 2>/dev/null)" || { echo "$2 $1: not reachable (OK if fenced/stopped)"; return 0; }
  echo "== $2 $1"
  psql "$dsn" -XAtq -F' | ' -c "select coalesce(nullif(application_name,''),'<none>'), usename, count(*)
     from pg_stat_activity where backend_type='client backend' and pid<>pg_backend_pid()
       and usename not in ('rdsadmin') and application_name not like 'dr-%'
     group by 1,2 order by 3 desc" 2>&1 || echo "$2 $1: query failed (fenced?)"
}

connections() {
  sessions "$TARGET_DB" TARGET
  [[ -n "${OLD_DB:-}" && "$OLD_DB" != "$TARGET_DB" ]] && sessions "$OLD_DB" OLD
  [[ -n "${REPLICA_DB:-}" && "$REPLICA_DB" != "$TARGET_DB" ]] && sessions "$REPLICA_DB" OLD_REPLICA
  return 0
}

# compare-counts: exact row counts of VERIFY_TABLES (space-separated schema.table) on OLD_DB vs TARGET_DB (TICKET-104).
# Replaces the outdated verification scripts: one list per env in env/<env>.env, no schema assumptions in code.
compare_counts() {
  : "${VERIFY_TABLES:?set VERIFY_TABLES in env/<env>.env, e.g. 'public.orders public.payments'}"
  local t a b tdsn odsn
  tdsn="$(dr_dsn "$TARGET_DB")"; odsn="$( [[ -n "${OLD_DB:-}" ]] && dr_dsn "$OLD_DB" 2>/dev/null || true)"
  printf '%-40s %15s %15s\n' table old target
  for t in $VERIFY_TABLES; do
    b="$(psql "$tdsn" -XAtqc "select count(*) from $t" 2>&1 | tail -1)"
    a="$( [[ -n "$odsn" ]] && psql "$odsn" -XAtqc "select count(*) from $t" 2>&1 | tail -1 || echo n/a)"
    printf '%-40s %15s %15s\n' "$t" "$a" "$b"
  done
  echo "(after a restore, target < old is expected: the difference = writes after the restore point)"
}

app_probe() {
  : "${APP_HEALTH_URLS:?space-separated deep-health URLs}"
  local rc=0 code
  for u in $APP_HEALTH_URLS; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$u" || echo 000)"
    if [[ "$code" == "200" ]]; then echo "PASS $code $u"; else echo "FAIL $code $u"; rc=1; fi
  done
  return $rc
}

case "${1:-}" in
  wait-promoted) wait_promoted ;;
  db)            db_probe ;;
  connections)   connections ;;
  compare-counts) compare_counts ;;
  app)           app_probe ;;
  *) echo "usage: $0 {wait-promoted|db|connections|compare-counts|app}"; exit 2 ;;
esac
