#!/usr/bin/env bash
# dr-secret-cutover.sh — CP-01: point the DB secret at TARGET_DB, sync into K8s (ESO), let Reloader roll the pods.
#   precheck      : app credentials from the CURRENT secret work on TARGET_DB and it is writable
#   fix-password  : reset the app role password on TARGET_DB to the current secret value (restored DBs have old passwords)
#   apply         : save previous version → put-secret-value(host/port/dbInstanceIdentifier) → ESO force-sync → wait Reloader rollouts
#   rollback      : move AWSCURRENT back to the saved previous version → ESO force-sync → wait rollouts
# Env: SECRET_ID, TARGET_DB, EKS_CONTEXT, K8S_NS, K8S_SECRET (K8S_SECRET_RO used automatically when SECRET_ID==SECRET_ID_RO),
#      MASTER_SECRET_ID (fix-password only). Never prints or stores passwords.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=dr-lib.sh
source "$HERE/dr-lib.sh"
: "${TARGET_DB:?run dr_set_target <id> first, or export TARGET_DB}" "${EKS_CONTEXT:?}" "${K8S_NS:?}" "${DR_EVIDENCE_DIR:?run dr_init first}"

if [[ -n "${SECRET_ID_RO:-}" && "$SECRET_ID" == "$SECRET_ID_RO" ]]; then K8S_SECRET="${K8S_SECRET_RO:-db-creds-ro}"; fi
: "${K8S_SECRET:?}"
SAFE_ID="${SECRET_ID//\//_}"
STATE="${DR_EVIDENCE_DIR}/aws/secret-${SAFE_ID}"
K="kubectl --context ${EKS_CONTEXT} -n ${K8S_NS}"

read -r NEW_HOST NEW_PORT <<<"$(dr_endpoint "$TARGET_DB")"
[[ -z "$NEW_HOST" || "$NEW_HOST" == "None" ]] && { echo "TARGET_DB $TARGET_DB has no endpoint (not available?)"; exit 1; }

secret_json() { aws secretsmanager get-secret-value --secret-id "$SECRET_ID" --version-stage "${1:-AWSCURRENT}" --query SecretString --output text; }
current_version() { aws secretsmanager describe-secret --secret-id "$SECRET_ID" \
  --query 'VersionIdsToStages' --output json | jq -r 'to_entries[] | select(.value | index("AWSCURRENT")) | .key'; }

precheck() {
  local s user pw
  s="$(secret_json)"; user="$(jq -r .username <<<"$s")"; pw="$(jq -r .password <<<"$s")"
  echo "secret $SECRET_ID: host(now)=$(jq -r .host <<<"$s") → target=$NEW_HOST:$NEW_PORT user=$user"
  if PGPASSWORD="$pw" psql "host=$NEW_HOST port=$NEW_PORT dbname=${DB_NAME:-app} user=$user sslmode=require connect_timeout=5 application_name=dr-precheck" \
       -XAtqc "select 'login OK as ' || current_user || ', in_recovery=' || pg_is_in_recovery()"; then
    return 0
  fi
  echo "LOGIN FAILED on $TARGET_DB with the current secret password."
  echo "Restored DBs keep passwords as of the restore point. Fix with: $0 fix-password (needs MASTER_SECRET_ID)"
  return 1
}

fix_password() {
  : "${MASTER_SECRET_ID:?MASTER_SECRET_ID (master user secret) required}"
  local s m
  s="$(secret_json)"; m="$(aws secretsmanager get-secret-value --secret-id "$MASTER_SECRET_ID" --query SecretString --output text)"
  # psql variables keep the password out of argv/ps output. NOTE: with log_statement=ddl/all the statement can reach the
  # PostgreSQL log — rotate the secret after stabilisation (CP03-S05).
  PGPASSWORD="$(jq -r .password <<<"$m")" psql "host=$NEW_HOST port=$NEW_PORT dbname=${DB_NAME:-app} user=$(jq -r .username <<<"$m") sslmode=require" \
    -v ON_ERROR_STOP=1 -v role="$(jq -r .username <<<"$s")" -v pw="$(jq -r .password <<<"$s")" -Xq <<'SQL'
ALTER ROLE :"role" WITH PASSWORD :'pw';
SQL
  dr_mark FIX_PASSWORD "role reset on ${TARGET_DB}"
  precheck
}

wait_k8s_secret_host() {
  local want="$1" deadline=$(( $(date +%s) + 180 )) got=""
  $K annotate externalsecret "$K8S_SECRET" force-sync="$(date +%s)" --overwrite >/dev/null
  while (( $(date +%s) < deadline )); do
    got="$($K get secret "$K8S_SECRET" -o json | jq -r '.data | (.DB_HOST // .host // empty)' | base64 -d 2>/dev/null || true)"
    [[ "$got" == "$want" ]] && { echo "K8s Secret $K8S_SECRET host=$got (synced)"; return 0; }
    sleep 5
  done
  echo "TIMEOUT: K8s Secret $K8S_SECRET host='$got' != '$want' — check ESO controller / ExternalSecret status"; return 1
}

apply() {
  local prev s new ver
  prev="$(current_version)"
  echo "$prev" > "${STATE}.previous-version"
  s="$(secret_json)"
  jq -r '{host, port, dbInstanceIdentifier}' <<<"$s" > "${STATE}.before.json"      # no password in evidence
  new="$(jq --arg h "$NEW_HOST" --argjson p "${NEW_PORT:-5432}" --arg id "$TARGET_DB" \
          '.host = $h | .port = $p | (if has("dbInstanceIdentifier") then .dbInstanceIdentifier = $id else . end)' <<<"$s")"
  "$HERE/dr-eks-rollout.sh" snapshot-generations "$K8S_SECRET"
  ver="$(aws secretsmanager put-secret-value --secret-id "$SECRET_ID" --secret-string "$new" --query VersionId --output text)"
  jq -n --arg prev "$prev" --arg new "$ver" --arg host "$NEW_HOST" --arg db "$TARGET_DB" \
     '{previous_version:$prev, new_version:$new, host:$host, db:$db}' > "${STATE}.after.json"
  dr_mark "SECRET_UPDATED:${SECRET_ID}" "version=${ver} host=${NEW_HOST}"
  [[ "$SECRET_ID" != "${SECRET_ID_RO:-}" ]] && dr_mark T6 "secret ${SECRET_ID} → ${TARGET_DB}"
  wait_k8s_secret_host "$NEW_HOST"
  "$HERE/dr-eks-rollout.sh" wait "$K8S_SECRET"
  [[ "$SECRET_ID" != "${SECRET_ID_RO:-}" ]] && dr_mark T7 "consumers of ${K8S_SECRET} rolled"
  echo "CUTOVER DONE: $SECRET_ID → $TARGET_DB ($NEW_HOST). Rollback: $0 rollback"
}

rollback() {
  local prev cur host
  prev="$(cat "${STATE}.previous-version")"; cur="$(current_version)"
  aws secretsmanager update-secret-version-stage --secret-id "$SECRET_ID" --version-stage AWSCURRENT \
    --move-to-version-id "$prev" --remove-from-version-id "$cur"
  host="$(secret_json | jq -r .host)"
  dr_mark "SECRET_ROLLBACK:${SECRET_ID}" "AWSCURRENT=${prev} host=${host}"
  "$HERE/dr-eks-rollout.sh" snapshot-generations "$K8S_SECRET"
  wait_k8s_secret_host "$host"
  "$HERE/dr-eks-rollout.sh" wait "$K8S_SECRET"
}

case "${1:-}" in
  precheck)     precheck ;;
  fix-password) fix_password ;;
  apply)        precheck && apply ;;
  rollback)     rollback ;;
  *) echo "usage: $0 {precheck|fix-password|apply|rollback}"; exit 2 ;;
esac
