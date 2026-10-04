#!/usr/bin/env bash
# dr-preflight.sh <mode> — automated pre-flight. PASS/WARN/FAIL per check; exit 1 on any FAIL.
#   replica : S2 (UAT/PROD) — replica health, lag vs RPO, LSN/heartbeat, creds, EKS/ESO/Reloader
#   restore : S3/S4 — restore window, snapshots, config inputs, EKS/ESO/Reloader
set -uo pipefail
MODE="${1:?usage: dr-preflight.sh replica|restore}"
: "${PRIMARY_DB:?}" "${SECRET_ID:?}" "${EKS_CONTEXT:?}" "${K8S_NS:?}" "${K8S_SECRET:?}"
REPLICA_LAG_MAX_S="${REPLICA_LAG_MAX_S:-300}"   # operational threshold; the RPO target (24 h) is far looser
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=dr-lib.sh
source "$HERE/dr-lib.sh"
dr_guard || exit 1

fails=0
pass() { printf 'PASS  %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; fails=$((fails+1)); }

check_primary() {
  local st; st="$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-instances --db-instance-identifier "$PRIMARY_DB" --query 'DBInstances[0].DBInstanceStatus' --output text 2>&1)"
  echo "INFO  primary $PRIMARY_DB status=$st"
}

check_replica() {
  : "${REPLICA_DB:?REPLICA_DB empty — S2 is not applicable in this environment}"
  read -r status source <<<"$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-instances --db-instance-identifier "$REPLICA_DB" \
    --query 'DBInstances[0].[DBInstanceStatus,ReadReplicaSourceDBInstanceIdentifier]' --output text)"
  [[ "$status" == "available" ]] && pass "replica status=$status" || fail "replica status=$status"
  [[ "$source" == *"$PRIMARY_DB"* ]] && pass "replica source=$source" || fail "replica source='$source' (expected $PRIMARY_DB)"
  local repl; repl="$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-instances --db-instance-identifier "$REPLICA_DB" \
    --query 'DBInstances[0].StatusInfos[?StatusType==`read replication`].Status | [0]' --output text)"
  [[ "$repl" == "replicating" ]] && pass "replication=$repl" || warn "replication=$repl (expected while the primary is down)"

  local lag; lag="$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" cloudwatch get-metric-statistics --namespace AWS/RDS --metric-name ReplicaLag \
    --dimensions Name=DBInstanceIdentifier,Value="$REPLICA_DB" \
    --start-time "$(date -u -d '-15 min' +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" --period 60 --statistics Maximum \
    --query 'max(Datapoints[].Maximum)' --output text)"
  if [[ "$lag" == "None" || -z "$lag" ]]; then warn "ReplicaLag: no datapoints (common when the primary is down) — rely on SQL/heartbeat"
  elif (( ${lag%.*} <= REPLICA_LAG_MAX_S )); then pass "ReplicaLag max15m=${lag}s <= ${REPLICA_LAG_MAX_S}s"
  else fail "ReplicaLag max15m=${lag}s > ${REPLICA_LAG_MAX_S}s — estimated data loss = lag; CTO acceptance at G1 (PROD)"; fi

  local dsn; dsn="$(dr_dsn "$REPLICA_DB")"
  if out="$(psql "$dsn" -XAtq -F' | ' -f "$HERE/../sql/10-preflight-replica.sql" 2>&1)"; then
    echo "$out" | sed 's/^/      /'; pass "app credentials from $SECRET_ID work on the replica"
  else
    fail "cannot query replica with $SECRET_ID: $out"
  fi
}

check_restore() {
  local win; win="$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-instance-automated-backups --db-instance-identifier "$PRIMARY_DB" \
    --query 'DBInstanceAutomatedBackups[0].RestoreWindow' --output json 2>/dev/null)"
  if [[ -n "$win" && "$win" != "null" ]]; then pass "PITR window: $(jq -c . <<<"$win")"; else warn "no automated backups / PITR window for $PRIMARY_DB → S3 snapshot only"; fi
  local n; n="$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-snapshots --db-instance-identifier "$PRIMARY_DB" --query 'length(DBSnapshots)' --output text 2>/dev/null)"
  (( ${n:-0} > 0 )) && pass "$n snapshots available for $PRIMARY_DB" || warn "no snapshots listed for $PRIMARY_DB (check AWS Backup vault / cross-account copies)"
  local src_ok=0; aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-instances --db-instance-identifier "$PRIMARY_DB" >/dev/null 2>&1 && src_ok=1
  # Restore settings come from a baseline of the source (dr-restore.sh capture): live if the source exists, else stored.
  local bl="${BASELINE_DIR:-$HERE/../../evidence/baselines/$DR_ENV}/baseline-${PRIMARY_DB}.json" age
  if (( src_ok )); then pass "restore baseline ← captured live from $PRIMARY_DB at restore time (all SGs, subnets, PG, tags, retention, …)"
  elif [[ -f "$bl" ]]; then
    age=$(( ($(date +%s) - $(date -d "$(jq -r .capturedAt "$bl")" +%s)) / 3600 ))
    (( age <= 24 )) && pass "stored baseline $bl (${age} h old)" || warn "stored baseline $bl is ${age} h old — settings may have drifted"
  else fail "$PRIMARY_DB not readable and no stored baseline $bl — run 'dr-restore.sh capture $PRIMARY_DB' on a schedule"; fi
  for v in DB_SUBNET_GROUP DB_SG DB_PARAM_GROUP DB_INSTANCE_CLASS; do
    [[ -n "${!v:-}" ]] && warn "override $v=${!v} in env profile wins over the baseline (validate will report it)"
  done
  if [[ -n "${DB_PARAM_GROUP:-}" ]]; then
    aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-parameter-groups --db-parameter-group-name "$DB_PARAM_GROUP" >/dev/null 2>&1 \
      && pass "parameter group $DB_PARAM_GROUP exists" || fail "parameter group $DB_PARAM_GROUP not found"
  fi
}

check_k8s() {
  local K="kubectl --context $EKS_CONTEXT -n $K8S_NS"
  if ! $K get ns "$K8S_NS" >/dev/null 2>&1; then fail "EKS $EKS_CONTEXT API not reachable"; return; fi
  pass "EKS $EKS_CONTEXT reachable"
  if [[ "${SECRET_MODE:-eso}" == k8s ]]; then
    local sj k missing="" owner
    sj="$($K get secret "$K8S_SECRET" -o json 2>/dev/null)" || { fail "Secret $K8S_SECRET not found"; return; }
    IFS=',' read -ra _keys <<<"${K8S_HOST_KEY:-DB_HOST}"
    for k in "${_keys[@]}"; do jq -e --arg k "$k" '.data[$k]' <<<"$sj" >/dev/null || missing+="$k "; done
    [[ -z "$missing" ]] && pass "Secret $K8S_SECRET has host keys ${K8S_HOST_KEY:-DB_HOST} (SECRET_MODE=k8s)" || fail "Secret $K8S_SECRET lacks keys: $missing"
    owner="$(jq -r '[.metadata.ownerReferences[]? | select(.kind=="ExternalSecret") | .name] | join(",")' <<<"$sj")"
    [[ -z "$owner" ]] && pass "Secret $K8S_SECRET not managed by ESO (direct update is safe)" || fail "Secret $K8S_SECRET is owned by ExternalSecret $owner — use SECRET_MODE=eso"
  else
    local es; es="$($K get externalsecret "$K8S_SECRET" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
    [[ "$es" == "True" ]] && pass "ExternalSecret $K8S_SECRET Ready" || fail "ExternalSecret $K8S_SECRET Ready='$es'"
  fi
  local rl; rl="$(kubectl --context "$EKS_CONTEXT" get deploy -A -o json 2>/dev/null \
    | jq '[.items[] | select(.metadata.name | test("reloader")) | (.status.availableReplicas // 0)] | add // 0')"
  (( ${rl:-0} >= 1 )) && pass "Reloader available replicas=${rl}" || fail "Reloader not running — cutover will need manual restarts (dr-eks-rollout.sh restart)"
  "$HERE/dr-eks-rollout.sh" inventory | sed 's/^/      /'
  if "$HERE/dr-eks-rollout.sh" inventory | grep -q 'reloader=NO'; then warn "some consumers lack the Reloader annotation — restart manually in CP01-S09"; else pass "all consumers Reloader-annotated"; fi
}

check_primary
case "$MODE" in
  replica) check_replica ;;
  restore) check_restore ;;
  *) echo "usage: $0 replica|restore"; exit 2 ;;
esac
check_k8s
aws --profile "$AWS_PROFILE" --region "$AWS_REGION" secretsmanager describe-secret --secret-id "$SECRET_ID" --query '{rotation:RotationEnabled,stages:VersionIdsToStages}' --output json \
  | sed 's/^/      /'

echo "----"
(( fails == 0 )) && { echo "PRE-FLIGHT: PASS"; exit 0; } || { echo "PRE-FLIGHT: ${fails} FAIL(s) — waiver required to proceed"; exit 1; }
