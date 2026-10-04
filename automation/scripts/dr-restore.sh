#!/usr/bin/env bash
# dr-restore.sh — S3/S4 restore helpers. Restore defaults are unsafe (default VPC SG, default parameter group,
# no deletion protection, single-AZ, backup retention not carried over), so every setting is passed explicitly.
#
#   list-snapshots <db-id>                         newest first + PITR window
#   snapshot <snapshot-id> <new-db-id>             restore a snapshot
#   pitr <source-db-id> <new-db-id> <ISO8601|latest>
#   wait <new-db-id>                               wait until available, print elapsed time, dr_mark T5
#   harden <new-db-id>                             post-restore: backup retention, deletion protection, PI; re-check parity
#
# Settings source (TICKET-103): taken from the SOURCE instance ($SOURCE_DB, default $PRIMARY_DB) when it still exists —
# ALL security groups, parameter group, subnet group, class, Multi-AZ, backup retention. Values set in env/<env>.env win.
# DRY_RUN=1 prints the commands only.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=dr-lib.sh
source "$HERE/dr-lib.sh"
dr_guard || exit 1
: "${DR_ENV:?}"
SOURCE_DB="${SOURCE_DB:-${PRIMARY_DB:-}}"

# Fill DB_* settings from the source instance where the profile leaves them empty.
load_source_settings() {
  local j
  [[ -n "$SOURCE_DB" ]] || return 0
  j="$(aws rds describe-db-instances --db-instance-identifier "$SOURCE_DB" --query 'DBInstances[0]' --output json 2>/dev/null)" || {
    echo "INFO source $SOURCE_DB not found — using env profile values only"; return 0; }
  : "${DB_INSTANCE_CLASS:=$(jq -r .DBInstanceClass <<<"$j")}"
  : "${DB_SUBNET_GROUP:=$(jq -r .DBSubnetGroup.DBSubnetGroupName <<<"$j")}"
  : "${DB_SG:=$(jq -r '[.VpcSecurityGroups[].VpcSecurityGroupId] | join(" ")' <<<"$j")}"      # ALL SGs, not only the first
  : "${DB_PARAM_GROUP:=$(jq -r '.DBParameterGroups[0].DBParameterGroupName' <<<"$j")}"
  : "${MULTI_AZ:=$(jq -r .MultiAZ <<<"$j")}"
  : "${BACKUP_RETENTION_DAYS:=$(jq -r .BackupRetentionPeriod <<<"$j")}"
  SRC_PI="$(jq -r '.PerformanceInsightsEnabled // false' <<<"$j")"
  # Warn when the profile differs from the live source (profile drift = runbook ambiguity)
  local live_sg; live_sg="$(jq -r '[.VpcSecurityGroups[].VpcSecurityGroupId] | sort | join(" ")' <<<"$j")"
  [[ "$(tr ' ' '\n' <<<"$DB_SG" | sort | xargs)" != "$live_sg" ]] && echo "WARN DB_SG='$DB_SG' differs from source SGs '$live_sg'"
  return 0
}

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

require_settings() {
  local v missing=0
  for v in DB_INSTANCE_CLASS DB_SUBNET_GROUP DB_SG DB_PARAM_GROUP; do
    [[ -n "${!v:-}" && "${!v}" != "null" ]] || { echo "MISSING $v (not in profile, source not readable)"; missing=1; }
  done
  (( missing == 0 )) || exit 1
  echo "settings: class=$DB_INSTANCE_CLASS subnets=$DB_SUBNET_GROUP sgs=[$DB_SG] pg=$DB_PARAM_GROUP multiAZ=${MULTI_AZ:-false} retention=${BACKUP_RETENTION_DAYS:-7}d"
}

run() {
  echo "+ $*"
  [[ "${DRY_RUN:-0}" == "1" ]] && return 0
  "$@" --query 'DBInstance.{id:DBInstanceIdentifier,status:DBInstanceStatus,multiAZ:MultiAZ}' --output table
  [[ -n "${DR_TIMELINE:-}" ]] && dr_mark T4 "restore started: $*" || true
}

wait_available() {
  local db="$1" start now st
  start=$(date +%s)
  while :; do
    st="$(aws rds describe-db-instances --db-instance-identifier "$db" --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo creating)"
    now=$(date +%s)
    printf '%s  %-12s elapsed %dm%02ds\n' "$(date -u +%H:%M:%SZ)" "$st" $(( (now-start)/60 )) $(( (now-start)%60 ))
    [[ "$st" == "available" ]] && break
    sleep 30
  done
  [[ -n "${DR_TIMELINE:-}" ]] && dr_mark T5 "$db available after $(( (now-start)/60 ))m$(( (now-start)%60 ))s" || true
}

harden() {
  local db="$1" f=(--backup-retention-period "${BACKUP_RETENTION_DAYS:-7}" --apply-immediately)
  [[ "${DR_ENV}" != "dev" ]] && f+=(--deletion-protection)
  [[ "${SRC_PI:-false}" == "true" ]] && f+=(--enable-performance-insights)
  echo "+ aws rds modify-db-instance --db-instance-identifier $db ${f[*]}"
  [[ "${DRY_RUN:-0}" == "1" ]] && return 0
  aws rds modify-db-instance --db-instance-identifier "$db" "${f[@]}" \
    --query 'DBInstance.{id:DBInstanceIdentifier,pending:PendingModifiedValues}' --output json
  sleep 20; wait_available "$db" >/dev/null
  aws rds describe-db-instances --db-instance-identifier "$db" \
    --query 'DBInstances[0].{retention:BackupRetentionPeriod,deletionProtection:DeletionProtection,sgs:VpcSecurityGroups[].VpcSecurityGroupId,pg:DBParameterGroups[0].DBParameterGroupName,multiAZ:MultiAZ}' --output json
  [[ -n "${SOURCE_DB}" ]] && "$HERE/rds-config-parity.sh" "$SOURCE_DB" "$db" || true
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
    load_source_settings; require_settings
    created="$(aws rds describe-db-snapshots --db-snapshot-identifier "$snap" --query 'DBSnapshots[0].SnapshotCreateTime' --output text 2>/dev/null || echo unknown)"
    echo "snapshot $snap created $created  → RPO reference point (recorded as RPO_SNAPSHOT)"
    [[ -n "${DR_TIMELINE:-}" && "$created" != "unknown" ]] && dr_mark RPO_SNAPSHOT "value=$created"
    dr_confirm "restore $snap → $new" || exit 1
    mapfile -t F < <(common_flags)
    run aws rds restore-db-instance-from-db-snapshot --db-instance-identifier "$new" --db-snapshot-identifier "$snap" "${F[@]}"
    ;;
  pitr)
    src="${2:?source db id}"; new="${3:?new db id}"; ts="${4:?restore time or latest}"
    SOURCE_DB="$src"; load_source_settings; require_settings
    mapfile -t F < <(common_flags)
    if [[ "$ts" == "latest" ]]; then T=(--use-latest-restorable-time); else T=(--restore-time "$ts"); fi
    [[ -n "${DR_TIMELINE:-}" && "$ts" != "latest" ]] && dr_mark RPO_RESTORE_TS "value=$ts"
    if aws rds describe-db-instances --db-instance-identifier "$src" >/dev/null 2>&1; then
      S=(--source-db-instance-identifier "$src")
    else  # source deleted → use retained automated backups
      rid="$(aws rds describe-db-instance-automated-backups --db-instance-identifier "$src" --query 'DBInstanceAutomatedBackups[0].DbiResourceId' --output text)"
      S=(--source-dbi-resource-id "$rid")
    fi
    dr_confirm "PITR $src → $new at $ts" || exit 1
    run aws rds restore-db-instance-to-point-in-time "${S[@]}" --target-db-instance-identifier "$new" "${T[@]}" "${F[@]}"
    ;;
  wait)   wait_available "${2:?db id}" ;;
  harden) dr_confirm "harden ${2:-}" || exit 1; load_source_settings >/dev/null; harden "${2:?db id}" ;;
  *) echo "usage: $0 {list-snapshots <db>|snapshot <snap> <new>|pitr <src> <new> <ts|latest>|wait <db>|harden <db>}"; exit 2 ;;
esac
