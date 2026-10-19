#!/usr/bin/env bash
# dr-fence-instance.sh — CP-04 fencing of the OLD instance (stops stray writes / split brain).
#   readonly   <db-id> : F1 — ALTER DATABASE ... default_transaction_read_only=on + terminate app sessions (needs MASTER_SECRET_ID)
#   quarantine <db-id> : F2 — replace the instance's security groups with QUARANTINE_SG (saves the original SGs)
#   restore    <db-id> : undo F1/F2 from the saved state
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=dr-lib.sh
source "$HERE/dr-lib.sh"
dr_guard || exit 1
CMD="${1:-}"; DB="${2:?db instance id}"
: "${DR_EVIDENCE_DIR:?run dr_init first}"
STATE="${DR_EVIDENCE_DIR}/db/fence-${DB}"

master_psql() {
  [[ "${DR_DB_ACCESS:-readonly}" != none ]] || { echo 'REFUSED: operator mode cannot run SQL fencing or read master credentials.' >&2; return 1; }
  : "${MASTER_SECRET_ID:?MASTER_SECRET_ID required}"
  local m addr port
  m="$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" secretsmanager get-secret-value --secret-id "$MASTER_SECRET_ID" --query SecretString --output text)"
  read -r addr port <<<"$(dr_endpoint "$DB")"
  PGPASSWORD="$(jq -r .password <<<"$m")" psql "host=$addr port=$port dbname=${DB_NAME:-app} user=$(jq -r .username <<<"$m") sslmode=${DR_PGSSLMODE:-require} connect_timeout=5 application_name=dr-fence" \
    -v ON_ERROR_STOP=1 -v dbname="${DB_NAME:-app}" -Xq
}

readonly_on() {
  master_psql <<'SQL'
ALTER DATABASE :"dbname" SET default_transaction_read_only = on;
SELECT count(pg_terminate_backend(pid)) AS terminated
FROM pg_stat_activity
WHERE datname = :'dbname' AND pid <> pg_backend_pid() AND backend_type = 'client backend'
  AND usename NOT IN ('rdsadmin') AND application_name NOT LIKE 'dr-%';
SQL
  echo readonly > "${STATE}.readonly"
  dr_mark FENCE "db=${DB} level=F1"
}

quarantine() {
  : "${QUARANTINE_SG:?QUARANTINE_SG required}"
  aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-instances --db-instance-identifier "$DB" \
    --query 'DBInstances[0].VpcSecurityGroups[].VpcSecurityGroupId' --output json > "${STATE}.sgs.json"
  aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds modify-db-instance --db-instance-identifier "$DB" --vpc-security-group-ids "$QUARANTINE_SG" --apply-immediately \
    --query 'DBInstance.VpcSecurityGroups' --output json
  if [[ "${DR_DB_ACCESS:-readonly}" == none ]]; then
    dr_mark QUARANTINE_REQUESTED "db=$DB level=F2; confirmation pending"
  else
    dr_mark FENCE "db=${DB} level=F2 saved=$(jq -c . "${STATE}.sgs.json")"
  fi
}

verify_quarantine() {
  [[ "$DR_ENV" != local ]] || { echo 'REFUSED: Moto security-group metadata does not enforce local PostgreSQL isolation; use physical stop.' >&2; return 1; }
  : "${QUARANTINE_SG:?}"
  local groups
  groups="$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-instances --db-instance-identifier "$DB" \
    --query 'DBInstances[0].VpcSecurityGroups' --output json)" || return 1
  jq -e --arg group "$QUARANTINE_SG" 'length == 1 and .[0].VpcSecurityGroupId == $group and .[0].Status == "active"' <<<"$groups" >/dev/null \
    || { echo 'REFUSED: quarantine security group is not confirmed active.' >&2; return 1; }
  dr_mark_once FENCE "db=$DB level=F2 quarantine group confirmed active; network rules require approved configuration"
}

local_stopped() {
  local receipt="$HERE/../../tests/local/.state/local-db-old.json" host port
  [[ "$DB" == app-pg-local && -f "$receipt" ]] \
    || { echo 'REFUSED: first run bash iac/local.sh db old stop on the host, then resume this step.' >&2; return 1; }
  jq -e '.container == "/drtest-pg-old" and .state.Running == false and .state.Status == "exited"' "$receipt" >/dev/null \
    || { echo 'REFUSED: host lifecycle evidence does not confirm the original fixture stopped.' >&2; return 1; }
  read -r host port <<<"$(dr_endpoint "$DB")"
  [[ "$host" == 172.30.0.21 && "$port" == 5432 ]] || return 1
  command -v pg_isready >/dev/null || { echo 'REFUSED: pg_isready is required to verify local isolation.' >&2; return 1; }
  local probe_rc=0
  pg_isready -h "$host" -p "$port" -t 3 >/dev/null 2>&1 || probe_rc=$?
  if [[ "$probe_rc" != 2 ]]; then
    echo 'REFUSED: original PostgreSQL is reachable or its isolation probe failed.' >&2
    return 1
  fi
  cp "$receipt" "${STATE}.stopped.json"
}

stop_instance() {
  if [[ "$DR_ENV" == local ]]; then
    local_stopped || return 1
    dr_mark LOCAL_STOP_CONFIRMED "db=$DB physical fixture stopped by approved host Terraform plan; not an RDS timing test"
    return 0
  fi
  local instance status
  instance="$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-instances \
    --db-instance-identifier "$DB" --query 'DBInstances[0]' --output json)" || return 1
  jq -e '.Engine == "postgres" and (.DBClusterIdentifier // "") == "" and
    (.ReadReplicaSourceDBInstanceIdentifier // "") == "" and
    ((.ReadReplicaDBInstanceIdentifiers // []) | length) == 0' <<<"$instance" >/dev/null \
    || { echo 'REFUSED: stop requires standalone RDS PostgreSQL without a cluster or read replicas; choose another fence.' >&2; return 1; }
  status="$(jq -r .DBInstanceStatus <<<"$instance")"
  case "$status" in
    stopped|stopping) echo "$DB is already $status; confirmation remains required before E2E."; return 0 ;;
    available) ;;
    *) echo "REFUSED: cannot request stop for $DB in status $status" >&2; return 1 ;;
  esac
  printf '%s\n' "$instance" > "${STATE}.before-stop.json"
  aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds stop-db-instance \
    --db-instance-identifier "$DB" --output json > "${STATE}.stop-requested.json" || return 1
  dr_mark STOP_REQUESTED "db=$DB level=F3; not yet confirmed isolated"
  echo 'Stop accepted; continue endpoint cutover and rollout while RDS stops. RDS auto-starts after seven days.'
}

wait_stopped() {
  if [[ "$DR_ENV" == local ]]; then
    local_stopped || return 1
    dr_mark_once FENCE "db=$DB level=F3 physical local fixture stopped (observation time)"
    return 0
  fi
  aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds wait db-instance-stopped \
    --db-instance-identifier "$DB" || return 1
  local instance
  instance="$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-instances \
    --db-instance-identifier "$DB" --query 'DBInstances[0]' --output json)" || return 1
  jq -e '.DBInstanceStatus == "stopped"' <<<"$instance" >/dev/null \
    || { echo "REFUSED: $DB is not confirmed stopped; do not declare service recovery." >&2; return 1; }
  printf '%s\n' "$instance" > "${STATE}.stopped.json"
  dr_mark_once FENCE "db=$DB level=F3 confirmed stopped (observation time)"
}

restore() {
  if [[ -f "${STATE}.stop-requested.json" || -f "${STATE}.stopped.json" ]]; then
    echo 'REFUSED: F3 needs a separately approved start, isolation and reconciliation procedure; restore only undoes F1/F2.' >&2
    return 1
  fi
  if [[ -f "${STATE}.sgs.json" ]]; then
    # shellcheck disable=SC2046
    aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds modify-db-instance --db-instance-identifier "$DB" --apply-immediately \
      --vpc-security-group-ids $(jq -r '.[]' "${STATE}.sgs.json") --query 'DBInstance.VpcSecurityGroups' --output json
    echo "restored SGs (security group change applies within a few minutes)"
  fi
  if [[ -f "${STATE}.readonly" ]]; then
    master_psql <<'SQL'
-- this session inherits the read-only default from F1 → switch it to read-write first
SET SESSION CHARACTERISTICS AS TRANSACTION READ WRITE;
ALTER DATABASE :"dbname" SET default_transaction_read_only = off;
SQL
    echo "read-only default removed (new sessions only)"
  fi
  dr_mark UNFENCE "db=${DB}"
}

if [[ "$CMD" != wait-stopped && "$CMD" != verify-quarantine ]]; then dr_confirm "fence ($CMD) $DB" || exit 1; fi
case "$CMD" in
  readonly)   readonly_on ;;
  quarantine) quarantine ;;
  stop)       stop_instance ;;
  wait-stopped) wait_stopped ;;
  verify-quarantine) verify_quarantine ;;
  restore)    restore ;;
  *) echo "usage: $0 {readonly|quarantine|stop|wait-stopped|restore} <db-id>"; exit 2 ;;
esac
