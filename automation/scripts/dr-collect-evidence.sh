#!/usr/bin/env bash
# dr-collect-evidence.sh — gather AWS-side evidence, build manifest with SHA-256, upload to WORM bucket.
# Safe to re-run: uploads create new object versions; nothing is overwritten under Object Lock.
set -euo pipefail
: "${DR_ID:?}" "${DR_ENV:?}" "${DR_REGION:?}" "${PRIMARY_REGION:?}" "${DR_DB:?}" "${HOSTED_ZONE_ID:?}" "${EVIDENCE_BUCKET:?}" "${DR_EVIDENCE_DIR:?}"
EVIDENCE_REGION="${EVIDENCE_REGION:-$DR_REGION}"      # write to the bucket replica in the healthy region
LOOKBACK_START="${LOOKBACK_START:-$(head -1 "${DR_EVIDENCE_DIR}/timeline.jsonl" | jq -r .ts)}"
A="${DR_EVIDENCE_DIR}/aws"; D="${DR_EVIDENCE_DIR}/db"; mkdir -p "$A" "$D"

ct() { # ct <region> <EventName>
  aws cloudtrail lookup-events --region "$1" --start-time "$LOOKBACK_START" \
    --lookup-attributes AttributeKey=EventName,AttributeValue="$2" --output json > "$A/cloudtrail-$2-$1.json" || true
}
for ev in PromoteReadReplica FailoverGlobalCluster SwitchoverGlobalCluster ModifyDBInstance \
          PutSecretValue StopReplicationToReplica CancelRotateSecret StartAutomationExecution; do
  ct "$DR_REGION" "$ev"
done
ct "$PRIMARY_REGION" RevokeSecurityGroupIngress
ct us-east-1 ChangeResourceRecordSets          # Route 53 = global service, logged in us-east-1
ct us-west-2 UpdateRoutingControlState         # ARC cluster endpoint region varies; adjust to yours

aws rds describe-db-instances --region "$DR_REGION" --db-instance-identifier "$DR_DB" > "$D/describe-db-instances-after.json"
aws rds describe-events --region "$DR_REGION" --source-type db-instance --source-identifier "$DR_DB" --duration 1440 > "$D/rds-events.json"
aws route53 list-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" --query "ResourceRecordSets[?Name=='${DB_CNAME:-}.']" > "$A/route53-record-after.json" || true
aws cloudwatch get-metric-statistics --region "$DR_REGION" --namespace AWS/RDS --metric-name ReplicaLag \
  --dimensions Name=DBInstanceIdentifier,Value="$DR_DB" --start-time "$(date -u -d '-6 hours' +%FT%TZ)" \
  --end-time "$(date -u +%FT%TZ)" --period 60 --statistics Maximum > "$A/cloudwatch-replicalag.json" || true
if [[ -n "${SSM_EXECUTION_ID:-}" ]]; then
  aws ssm get-automation-execution --region "$DR_REGION" --automation-execution-id "$SSM_EXECUTION_ID" > "$A/ssm-execution.json"
fi

# KPIs
python3 "$(dirname "$0")/dr-rto-rpo-calc.py" "${DR_EVIDENCE_DIR}/timeline.jsonl" --out "${DR_EVIDENCE_DIR}" || true

# Manifest (sha256 of every file except the manifest itself)
( cd "$DR_EVIDENCE_DIR"
  find . -type f ! -name manifest.json -print0 | sort -z | xargs -0 sha256sum \
  | jq -R 'capture("^(?<sha256>[0-9a-f]{64})  \\./(?<path>.*)$")' | jq -s \
      --arg id "$DR_ID" --arg env "$DR_ENV" --arg by "$(aws sts get-caller-identity --query Arn --output text)" \
      --arg at "$(date -u +%FT%TZ)" --arg git "$(git rev-parse HEAD 2>/dev/null || echo n/a)" \
      '{dr_id:$id, env:$env, collected_by:$by, collected_at:$at, runbook:"RB-DR-RDS-001", runbook_git_sha:$git, files:.}' \
  > manifest.json )
MANIFEST_SHA="$(sha256sum "${DR_EVIDENCE_DIR}/manifest.json" | cut -d' ' -f1)"

PREFIX="s3://${EVIDENCE_BUCKET}/${DR_ENV}/$(date -u +%Y)/${DR_ID}/"
aws s3 cp --region "$EVIDENCE_REGION" --recursive --sse aws:kms "${DR_EVIDENCE_DIR}/" "$PREFIX"
echo "Evidence uploaded to ${PREFIX}"
echo "POST IN INCIDENT CHANNEL ->  EVIDENCE: ${PREFIX}manifest.json sha256=${MANIFEST_SHA}"
