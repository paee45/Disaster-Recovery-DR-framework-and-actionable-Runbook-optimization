#!/usr/bin/env bash
# rds-config-parity.sh [--alarms] <reference-db-id> <new-db-id>
# CP-03: show configuration differences between the old/reference instance and the new primary.
# If the reference instance no longer exists, set REFERENCE_JSON=<saved describe-db-instances output> (from P2-S01 evidence).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=dr-lib.sh
source "$HERE/dr-lib.sh"
dr_guard || exit 1
ALARMS=0; [[ "${1:-}" == "--alarms" ]] && { ALARMS=1; shift; }
REF="${1:?reference db id}"; NEW="${2:?new db id}"

project='.DBInstances[0] | {
  DBInstanceClass, Engine, EngineVersion, StorageType, AllocatedStorage, Iops, StorageThroughput, MaxAllocatedStorage,
  MultiAZ, PubliclyAccessible, DeletionProtection, BackupRetentionPeriod, PreferredBackupWindow, PreferredMaintenanceWindow,
  AutoMinorVersionUpgrade, CopyTagsToSnapshot, IAMDatabaseAuthenticationEnabled, PerformanceInsightsEnabled,
  MonitoringInterval, CACertificateIdentifier, StorageEncrypted,
  DBSubnetGroup: .DBSubnetGroup.DBSubnetGroupName,
  VpcSecurityGroups: ([.VpcSecurityGroups[].VpcSecurityGroupId] | sort),
  DBParameterGroups: ([.DBParameterGroups[] | .DBParameterGroupName + ":" + .ParameterApplyStatus] | sort),
  CloudwatchLogsExports: ((.EnabledCloudwatchLogsExports // []) | sort),
  Tags: ([.TagList[]? | select(.Key | test("^(aws:|dr-restore)") | not) | .Key + "=" + .Value] | sort),
  ReadReplicas: (.ReadReplicaDBInstanceIdentifiers | length)
}'

ref_json() { if [[ -n "${REFERENCE_JSON:-}" ]]; then cat "$REFERENCE_JSON"; else aws rds describe-db-instances --db-instance-identifier "$REF"; fi; }
a="$(ref_json | jq -S "$project")"
b="$(aws rds describe-db-instances --db-instance-identifier "$NEW" | jq -S "$project")"

echo "attribute | ${REF} | ${NEW}"
jq -rn --argjson a "$a" --argjson b "$b" '
  ($a | keys_unsorted[]) as $k | select($a[$k] != $b[$k]) | "DIFF  \($k) | \($a[$k] | tojson) | \($b[$k] | tojson)"'
echo "(expected diffs after S2/S3/S4: ReadReplicas, possibly MultiAZ until CP03-S03, Tags dr-restore)"

if (( ALARMS )); then
  echo "--- CloudWatch alarms on DBInstanceIdentifier"
  list() { aws cloudwatch describe-alarms --query "MetricAlarms[?Dimensions[?Name=='DBInstanceIdentifier' && Value=='$1']].AlarmName" --output text | tr '\t' '\n' | sed '/^$/d' | sort; }
  old="$(list "$REF")"; new="$(list "$NEW")"
  echo "on ${REF}: $(grep -c . <<<"$old" || true)  on ${NEW}: $(grep -c . <<<"$new" || true)"
  comm -23 <(sed "s/${REF}/<db>/g" <<<"$old") <(sed "s/${NEW}/<db>/g" <<<"$new") | sed 's/^/MISSING on new: /'
fi
