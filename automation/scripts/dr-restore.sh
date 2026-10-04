#!/usr/bin/env bash
# dr-restore.sh — S3/S4 restore helpers with ALL hardening flags explicit (restore defaults are unsafe:
# default VPC SG, default parameter group, no deletion protection, single-AZ).
#   list-snapshots <db-id>
#   snapshot <snapshot-id> <new-db-id>
#   pitr <source-db-id> <new-db-id> <restore-time ISO8601 | latest>
# DRY_RUN=1 prints the command only. Profile vars: DB_INSTANCE_CLASS DB_SUBNET_GROUP DB_SG DB_PARAM_GROUP MULTI_AZ
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=dr-lib.sh
source "$HERE/dr-lib.sh"
: "${DB_INSTANCE_CLASS:?}" "${DB_SUBNET_GROUP:?}" "${DB_SG:?}" "${DB_PARAM_GROUP:?}" "${DR_ENV:?}"

common_flags() {
  local sgs tags
  read -ra sgs <<<"$DB_SG"                 # one or more SG ids, space separated
  read -ra tags <<<"${EXTRA_TAGS:-}"       # e.g. "Key=backup-plan,Value=prod-daily"
  local f=(--db-instance-class "$DB_INSTANCE_CLASS" --db-subnet-group-name "$DB_SUBNET_GROUP"
           --vpc-security-group-ids "${sgs[@]}" --db-parameter-group-name "$DB_PARAM_GROUP"
           --no-publicly-accessible --copy-tags-to-snapshot
           --enable-cloudwatch-logs-exports postgresql upgrade
           --tags "Key=dr-restore,Value=${DR_ID:-manual}" "Key=env,Value=${DR_ENV}" "${tags[@]}")
  [[ "${MULTI_AZ:-false}" == "true" ]] && f+=(--multi-az) || f+=(--no-multi-az)
  [[ "${DR_ENV}" != "dev" ]] && f+=(--deletion-protection)
  printf '%s\n' "${f[@]}"
}

run() {
  echo "+ $*"
  [[ "${DRY_RUN:-0}" == "1" ]] && return 0
  "$@" --query 'DBInstance.{id:DBInstanceIdentifier,status:DBInstanceStatus,multiAZ:MultiAZ}' --output table
  [[ -n "${DR_TIMELINE:-}" ]] && dr_mark RESTORE_STARTED "$*" || true
}

case "${1:-}" in
  list-snapshots)
    db="${2:?db id}"
    aws rds describe-db-snapshots --db-instance-identifier "$db" --include-shared \
      --query 'reverse(sort_by(DBSnapshots,&SnapshotCreateTime))[].[DBSnapshotIdentifier,SnapshotType,SnapshotCreateTime,Status,Encrypted,AllocatedStorage]' \
      --output table
    echo "PITR window:"
    aws rds describe-db-instance-automated-backups --db-instance-identifier "$db" \
      --query 'DBInstanceAutomatedBackups[].{status:Status,window:RestoreWindow,resourceId:DbiResourceId}' --output table || true
    ;;
  snapshot)
    snap="${2:?snapshot id}"; new="${3:?new db id}"
    mapfile -t F < <(common_flags)
    run aws rds restore-db-instance-from-db-snapshot --db-instance-identifier "$new" --db-snapshot-identifier "$snap" "${F[@]}"
    ;;
  pitr)
    src="${2:?source db id}"; new="${3:?new db id}"; ts="${4:?restore time or latest}"
    mapfile -t F < <(common_flags)
    if [[ "$ts" == "latest" ]]; then T=(--use-latest-restorable-time); else T=(--restore-time "$ts"); fi
    if aws rds describe-db-instances --db-instance-identifier "$src" >/dev/null 2>&1; then
      S=(--source-db-instance-identifier "$src")
    else  # source deleted → use retained automated backups
      rid="$(aws rds describe-db-instance-automated-backups --db-instance-identifier "$src" --query 'DBInstanceAutomatedBackups[0].DbiResourceId' --output text)"
      S=(--source-dbi-resource-id "$rid")
    fi
    run aws rds restore-db-instance-to-point-in-time "${S[@]}" --target-db-instance-identifier "$new" "${T[@]}" "${F[@]}"
    ;;
  *) echo "usage: $0 {list-snapshots <db>|snapshot <snap> <new>|pitr <src> <new> <ts|latest>}"; exit 2 ;;
esac
