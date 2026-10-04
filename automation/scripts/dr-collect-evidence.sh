#!/usr/bin/env bash
# dr-collect-evidence.sh — CP-05: gather AWS evidence, compute KPIs, build manifest (SHA-256), upload to the WORM bucket.
# Safe to re-run (Object Lock keeps every version). Never collects secret VALUES — only version IDs/stages and host.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=dr-lib.sh
source "$HERE/dr-lib.sh"
dr_guard || exit 1
: "${DR_ID:?}" "${DR_EVIDENCE_DIR:?run dr_init first}" "${EVIDENCE_BUCKET:?}"
LOOKBACK_START="${LOOKBACK_START:-$(head -1 "${DR_EVIDENCE_DIR}/timeline.jsonl" | jq -r .ts)}"
A="${DR_EVIDENCE_DIR}/aws"; D="${DR_EVIDENCE_DIR}/db"; mkdir -p "$A" "$D"

ct() { # CloudTrail management events by name (regional; RDS/Secrets Manager/EC2 are regional services)
  aws cloudtrail lookup-events --start-time "$LOOKBACK_START" \
    --lookup-attributes AttributeKey=EventName,AttributeValue="$1" --output json > "$A/cloudtrail-$1.json" || true
}
for ev in PromoteReadReplica RestoreDBInstanceFromDBSnapshot RestoreDBInstanceToPointInTime RebootDBInstance \
          ModifyDBInstance CreateDBInstanceReadReplica CreateDBSnapshot StopDBInstance DeleteDBInstance \
          PutSecretValue UpdateSecretVersionStage CancelRotateSecret RotateSecret StartAutomationExecution; do
  ct "$ev"
done

for db in ${TARGET_DB:-} ${OLD_DB:-} ${REPLICA_DB:-}; do
  aws rds describe-db-instances --db-instance-identifier "$db" > "$D/describe-${db}.json" 2>/dev/null || echo "{\"absent\":\"$db\"}" > "$D/describe-${db}.json"
  aws rds describe-events --source-type db-instance --source-identifier "$db" --duration 2880 > "$D/rds-events-${db}.json" 2>/dev/null || true
done
for s in "$SECRET_ID" ${SECRET_ID_RO:-}; do
  aws secretsmanager describe-secret --secret-id "$s" \
    --query '{name:Name,rotation:RotationEnabled,lastChanged:LastChangedDate,stages:VersionIdsToStages}' > "$A/secret-meta-${s//\//_}.json" || true
done
if [[ -n "${SSM_EXECUTION_ID:-}" ]]; then
  aws ssm get-automation-execution --automation-execution-id "$SSM_EXECUTION_ID" > "$A/ssm-execution.json"
fi
if [[ -n "${REPLICA_DB:-}" ]]; then
  aws cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name ReplicaLag \
    --dimensions Name=DBInstanceIdentifier,Value="$REPLICA_DB" --start-time "$(date -u -d '-6 hours' +%FT%TZ)" \
    --end-time "$(date -u +%FT%TZ)" --period 60 --statistics Maximum > "$A/cloudwatch-replicalag.json" || true
fi

python3 "$HERE/dr-rto-rpo-calc.py" "${DR_EVIDENCE_DIR}/timeline.jsonl" --out "${DR_EVIDENCE_DIR}" \
  --rto-target-min "${RTO_TARGET_MIN:-30}" --rpo-target-s "${RPO_TARGET_S:-86400}" || true

( cd "$DR_EVIDENCE_DIR"
  find . -type f ! -name manifest.json -print0 | sort -z | xargs -0 sha256sum \
  | jq -R 'capture("^(?<sha256>[0-9a-f]{64})  \\./(?<path>.*)$")' | jq -s \
      --arg id "$DR_ID" --arg env "$DR_ENV" --arg sc "${DR_SCENARIO:-}" --arg by "$(aws sts get-caller-identity --query Arn --output text)" \
      --arg at "$(date -u +%FT%TZ)" --arg git "$(git rev-parse HEAD 2>/dev/null || echo n/a)" \
      '{dr_id:$id, env:$env, scenario:$sc, collected_by:$by, collected_at:$at, runbook_git_sha:$git, files:.}' \
  > manifest.json )
MANIFEST_SHA="$(sha256sum "${DR_EVIDENCE_DIR}/manifest.json" | cut -d' ' -f1)"

PREFIX="s3://${EVIDENCE_BUCKET}/${DR_ENV}/$(date -u +%Y)/${DR_ID}/"
aws s3 cp --recursive --sse aws:kms "${DR_EVIDENCE_DIR}/" "$PREFIX"
dr_mark EVIDENCE_UPLOADED "prefix=${PREFIX} manifest_sha256=${MANIFEST_SHA}"
echo "POST IN INCIDENT CHANNEL ->  EVIDENCE: ${PREFIX}manifest.json sha256=${MANIFEST_SHA}"
