#!/usr/bin/env bash
# dr-verify.sh — verification helpers.
#   wait-promoted : block until the replica is a standalone, writable primary (P2-S07)
#   db            : writability + heartbeat probe on the DR instance
#   app           : deep health of critical services via Region B ingress
set -euo pipefail
: "${DR_REGION:?}" "${DR_DB:?}" "${DR_DSN:?run dr_init first}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-1200}"

wait_promoted() {
  local deadline=$(( $(date +%s) + TIMEOUT_SECONDS )) seen_modifying=0
  while (( $(date +%s) < deadline )); do
    read -r status source <<<"$(aws rds describe-db-instances --region "$DR_REGION" --db-instance-identifier "$DR_DB" \
      --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier]' --output text)"
    [[ "$status" != "available" ]] && seen_modifying=1
    echo "$(date -u +%FT%TZ) status=${status} source=${source} seen_non_available=${seen_modifying}"
    # Pitfall: right after the API call the instance may still report 'available' with a source set.
    if [[ "$status" == "available" && ( "$source" == "None" || -z "$source" ) ]]; then
      if [[ "$(psql "$DR_DSN" -XAtqc 'select pg_is_in_recovery()' 2>/dev/null)" == "f" ]]; then
        echo "PROMOTED: standalone, not in recovery"; return 0
      fi
    fi
    sleep 15
  done
  echo "TIMEOUT waiting for promotion after ${TIMEOUT_SECONDS}s"; return 1
}

db_probe() {
  psql "$DR_DSN" -XAtq -v ON_ERROR_STOP=1 <<'SQL'
select 'in_recovery=' || pg_is_in_recovery();
create schema if not exists dr;
create table if not exists dr.write_probe(id bigserial primary key, ts timestamptz default clock_timestamp(), note text);
insert into dr.write_probe(note) values ('dr-verify') returning 'write_probe_ok id=' || id || ' ts=' || ts;
select 'heartbeat_last=' || coalesce((select ts::text from dr.heartbeat where id = 1), 'n/a');
SQL
}

app_probe() {
  : "${APP_HEALTH_URLS:?space-separated list of deep-health URLs in Region B}"
  local rc=0
  for u in $APP_HEALTH_URLS; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$u" || echo 000)"
    if [[ "$code" == "200" ]]; then echo "PASS $code $u"; else echo "FAIL $code $u"; rc=1; fi
  done
  return $rc
}

case "${1:-}" in
  wait-promoted) wait_promoted ;;
  db)            db_probe ;;
  app)           app_probe ;;
  *) echo "usage: $0 {wait-promoted|db|app}"; exit 2 ;;
esac
