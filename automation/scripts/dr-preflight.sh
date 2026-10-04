#!/usr/bin/env bash
# dr-preflight.sh — Phase 1 automated pre-flight. Prints PASS/WARN/FAIL per check; exit 1 on any FAIL.
# Usage (from runbook): dr_run preflight ./automation/scripts/dr-preflight.sh
set -uo pipefail
: "${DR_REGION:?}" "${DR_DB:?}" "${PRIMARY_DB:?}" "${SECRET_ID:?}" "${EKS_DR:?}" "${K8S_NS:?}" "${DR_DSN:?run dr_init first}"
RPO_SECONDS="${RPO_SECONDS:-300}"
SSM_DOC="${SSM_DOC:-DR-RdsPostgresRegionalFailover}"
EXPECTED_SSM_VERSION="${EXPECTED_SSM_VERSION:-}"

fails=0
pass() { printf 'PASS  %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; fails=$((fails+1)); }

# 1. Replica status and topology
read -r status source <<<"$(aws rds describe-db-instances --region "$DR_REGION" --db-instance-identifier "$DR_DB" \
  --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier]' --output text)"
[[ "$status" == "available" ]] && pass "replica status=$status" || fail "replica status=$status"
[[ "$source" == *"$PRIMARY_DB"* ]] && pass "replica source=$source" || fail "replica source='$source' (expected $PRIMARY_DB)"
repl_state="$(aws rds describe-db-instances --region "$DR_REGION" --db-instance-identifier "$DR_DB" \
  --query 'DBInstances[0].StatusInfos[?StatusType==`read replication`].Status | [0]' --output text)"
[[ "$repl_state" == "replicating" ]] && pass "replication state=$repl_state" || warn "replication state=$repl_state (expected during a primary outage: error/stopped)"

# 2. CloudWatch ReplicaLag, max over last 15 min
lag="$(aws cloudwatch get-metric-statistics --region "$DR_REGION" --namespace AWS/RDS --metric-name ReplicaLag \
  --dimensions Name=DBInstanceIdentifier,Value="$DR_DB" \
  --start-time "$(date -u -d '-15 min' +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" --period 60 --statistics Maximum \
  --query 'max(Datapoints[].Maximum)' --output text)"
if [[ "$lag" == "None" || -z "$lag" ]]; then warn "ReplicaLag: no datapoints (metric gap is common when the primary is down)";
elif (( ${lag%.*} <= RPO_SECONDS )); then pass "ReplicaLag max15m=${lag}s <= RPO ${RPO_SECONDS}s";
else fail "ReplicaLag max15m=${lag}s > RPO ${RPO_SECONDS}s — estimated data loss exceeds RPO; exec approval required at G1"; fi

# 3. SQL on replica (also proves the replica secret + credentials work)
if out="$(psql "$DR_DSN" -XAtq -F' | ' -f "$(dirname "$0")/../sql/10-preflight-replica.sql" 2>&1)"; then
  echo "$out" | sed 's/^/      /'
  [[ "$(psql "$DR_DSN" -XAtqc 'select pg_is_in_recovery()')" == "t" ]] && pass "replica in recovery (not yet promoted)" \
    || warn "replica NOT in recovery — already promoted?"
else
  fail "cannot query replica with secret ${SECRET_ID}@${DR_REGION}: ${out}"
fi

# 4. DR EKS: API reachable, ExternalSecret ready, critical deployments present
if kubectl --context "$EKS_DR" -n "$K8S_NS" get ns "$K8S_NS" >/dev/null 2>&1; then
  pass "EKS $EKS_DR API reachable"
  es="$(kubectl --context "$EKS_DR" -n "$K8S_NS" get externalsecret db-creds -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
  [[ "$es" == "True" ]] && pass "ExternalSecret db-creds Ready" || fail "ExternalSecret db-creds Ready='$es'"
  n="$(kubectl --context "$EKS_DR" -n "$K8S_NS" get deploy -l "${DR_SELECTOR:-dr.example.com/tier}" --no-headers 2>/dev/null | wc -l)"
  (( n > 0 )) && pass "$n DR-labelled deployments present" || fail "no DR-labelled deployments in $EKS_DR/$K8S_NS"
else
  fail "EKS $EKS_DR API not reachable (check kubeconfig context / access entry for DRExecutorRole)"
fi

# 5. SSM document present in DR region and version pinned
ver="$(aws ssm describe-document --region "$DR_REGION" --name "$SSM_DOC" --query 'Document.DefaultVersion' --output text 2>/dev/null)"
if [[ -z "$ver" || "$ver" == "None" ]]; then fail "SSM doc $SSM_DOC missing in $DR_REGION"
elif [[ -n "$EXPECTED_SSM_VERSION" && "$ver" != "$EXPECTED_SSM_VERSION" ]]; then warn "SSM doc version $ver != runbook pin $EXPECTED_SSM_VERSION"
else pass "SSM doc $SSM_DOC v$ver"; fi

echo "----"
(( fails == 0 )) && { echo "PRE-FLIGHT: PASS"; exit 0; } || { echo "PRE-FLIGHT: ${fails} FAIL(s) — IC waiver required to proceed"; exit 1; }
