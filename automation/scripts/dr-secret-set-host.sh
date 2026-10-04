#!/usr/bin/env bash
# dr-secret-set-host.sh — LEGACY path (P3-S02): secret stores the instance endpoint, so it must be rewritten.
# Target state is a stable CNAME in the secret, which makes this script unnecessary.
set -euo pipefail
: "${DR_REGION:?}" "${DR_DB:?}" "${SECRET_ID:?}" "${DR_EVIDENCE_DIR:?}"

new_host="$(aws rds describe-db-instances --region "$DR_REGION" --db-instance-identifier "$DR_DB" \
            --query 'DBInstances[0].Endpoint.Address' --output text)"

# Replica secrets are read-only. If it is still a replica, it must be promoted to standalone first.
primary_region="$(aws secretsmanager describe-secret --region "$DR_REGION" --secret-id "$SECRET_ID" \
                  --query PrimaryRegion --output text)"
if [[ "$primary_region" != "$DR_REGION" ]]; then
  echo "Secret is a replica of ${primary_region}. Run (after IC approval):"
  echo "  aws secretsmanager stop-replication-to-replica --region ${DR_REGION} --secret-id ${SECRET_ID}"
  exit 3
fi

current="$(aws secretsmanager get-secret-value --region "$DR_REGION" --secret-id "$SECRET_ID" --query SecretString --output text)"
jq -r '.host' <<<"$current" > "${DR_EVIDENCE_DIR}/aws/secret-host-before.txt"   # host only, never the password
updated="$(jq --arg h "$new_host" '.host = $h' <<<"$current")"
aws secretsmanager put-secret-value --region "$DR_REGION" --secret-id "$SECRET_ID" --secret-string "$updated" \
  --query '{VersionId:VersionId}' | tee "${DR_EVIDENCE_DIR}/aws/secret-put.json"
echo "host -> ${new_host}. ESO refresh + Reloader will roll the pods; force with: kubectl annotate externalsecret db-creds force-sync=\$(date +%s) --overwrite"
