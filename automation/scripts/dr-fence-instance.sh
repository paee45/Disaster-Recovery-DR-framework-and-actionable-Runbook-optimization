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
  dr_mark FENCE "db=${DB} level=F2 saved=$(jq -c . "${STATE}.sgs.json")"
}

restore() {
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

dr_confirm "fence ($CMD) $DB" || exit 1
case "$CMD" in
  readonly)   readonly_on ;;
  quarantine) quarantine ;;
  restore)    restore ;;
  *) echo "usage: $0 {readonly|quarantine|restore} <db-id>"; exit 2 ;;
esac
