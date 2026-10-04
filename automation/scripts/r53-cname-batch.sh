#!/usr/bin/env bash
# r53-cname-batch.sh <record-name> <target> [ttl] — prints a Route 53 change batch (UPSERT CNAME) to stdout.
set -euo pipefail
name="${1:?record name}"; target="${2:?target}"; ttl="${3:-30}"
jq -n --arg n "$name" --arg t "$target" --argjson ttl "$ttl" --arg c "DR ${DR_ID:-manual} $(date -u +%FT%TZ)" '{
  Comment: $c,
  Changes: [{Action: "UPSERT", ResourceRecordSet: {Name: $n, Type: "CNAME", TTL: $ttl, ResourceRecords: [{Value: $t}]}}]
}'
