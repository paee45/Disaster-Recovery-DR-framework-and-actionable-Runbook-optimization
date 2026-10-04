#!/usr/bin/env bash
# dr-secret-cutover.sh — CP-01: point the app at TARGET_DB by changing the endpoint in its secret; Reloader rolls the pods.
#
# SECRET_MODE=k8s (simple, no ESO): the Kubernetes Secret is patched directly by k8s-secret-endpoint.sh — every key in
#   K8S_HOST_KEY (comma list, e.g. POSTGRES_DB_HOST1,POSTGRES_DB_HOST2) gets the same endpoint, and every change is
#   recorded with its ID (CUTOVER_ID, default DR_ID) in the ledger ConfigMap dr-endpoint-ledger-<secret>.
# SECRET_MODE=eso (default; to-do target for all envs): Secrets Manager put-secret-value → ESO force-sync → K8s Secret.
#
#   precheck          : app credentials (from the secret) work on TARGET_DB and it is writable
#   fix-password      : reset the app role password on TARGET_DB to the secret value (restored DBs have old passwords)
#   apply             : record previous endpoint → write TARGET_DB endpoint → wait for the Reloader rollouts
#   rollback          : undo the latest change (k8s: ledger; eso: AWSCURRENT back to the saved version) → wait rollouts
#   failback <id>     : (k8s) restore the endpoint that was in place BEFORE change <id> (see `history`) → wait rollouts
#   history | show    : (k8s) ledger of changes / current endpoint + last change id
# Env: TARGET_DB, EKS_CONTEXT, K8S_NS, K8S_SECRET, K8S_HOST_KEY, [K8S_PORT_KEY], SECRET_MODE, CUTOVER_ID,
#      eso: SECRET_ID (K8S_SECRET_RO used when SECRET_ID==SECRET_ID_RO) · k8s: K8S_USER_KEY/K8S_PASSWORD_KEY
#      (default POSTGRES_DB_USER/POSTGRES_DB_PASSWORD) · fix-password: MASTER_SECRET_ID. Never prints or stores passwords.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=dr-lib.sh
source "$HERE/dr-lib.sh"
dr_guard || exit 1
: "${EKS_CONTEXT:?}" "${K8S_NS:?}" "${DR_EVIDENCE_DIR:?run dr_init first}"
SECRET_MODE="${SECRET_MODE:-eso}"; [[ "$SECRET_MODE" =~ ^(k8s|eso)$ ]] || { echo "SECRET_MODE must be k8s or eso"; exit 2; }
CMD="${1:-}"

if [[ -n "${SECRET_ID_RO:-}" && "${SECRET_ID:-}" == "$SECRET_ID_RO" ]]; then K8S_SECRET="${K8S_SECRET_RO:-db-creds-ro}"; fi
: "${K8S_SECRET:?}"
[[ "$SECRET_MODE" == k8s ]] || : "${SECRET_ID:?SECRET_ID required for SECRET_MODE=eso}"
SAFE_ID="${SECRET_ID:-k8s}"; SAFE_ID="${SAFE_ID//\//_}"
STATE="${DR_EVIDENCE_DIR}/aws/secret-${SAFE_ID}"
K="kubectl --context ${EKS_CONTEXT} -n ${K8S_NS}"

IFS=',' read -ra HOST_KEYS <<<"${K8S_HOST_KEY:-DB_HOST}"
EP=("$HERE/k8s-secret-endpoint.sh" --context "$EKS_CONTEXT" -n "$K8S_NS" -s "$K8S_SECRET" -k "${K8S_HOST_KEY:-DB_HOST}" ${K8S_PORT_KEY:+--port-key "$K8S_PORT_KEY"})
NEW_HOST=""; NEW_PORT=""
if [[ "$CMD" =~ ^(precheck|fix-password|apply)$ ]]; then
  : "${TARGET_DB:?run dr_set_target <id> first, or export TARGET_DB}"
  read -r NEW_HOST NEW_PORT <<<"$(dr_endpoint "$TARGET_DB")"
  [[ -z "$NEW_HOST" || "$NEW_HOST" == "None" ]] && { echo "TARGET_DB $TARGET_DB has no endpoint (not available?)"; exit 1; }
fi

secret_json() { aws --profile "$AWS_PROFILE" --region "$AWS_REGION" secretsmanager get-secret-value --secret-id "$SECRET_ID" --version-stage "${1:-AWSCURRENT}" --query SecretString --output text; }
current_version() { aws --profile "$AWS_PROFILE" --region "$AWS_REGION" secretsmanager describe-secret --secret-id "$SECRET_ID" \
  --query 'VersionIdsToStages' --output json | jq -r 'to_entries[] | select(.value | index("AWSCURRENT")) | .key'; }

# app credentials + current host, from Secrets Manager (eso) or from the K8s Secret itself (k8s) → "user<TAB>pw<TAB>host"
app_creds() {
  if [[ "$SECRET_MODE" == k8s ]]; then
    $K get secret "$K8S_SECRET" -o json | jq -r --arg u "${K8S_USER_KEY:-POSTGRES_DB_USER}" --arg p "${K8S_PASSWORD_KEY:-POSTGRES_DB_PASSWORD}" \
      --arg h "${HOST_KEYS[0]}" '[(.data[$u] // "" | @base64d), (.data[$p] // "" | @base64d), (.data[$h] // "" | @base64d)] | @tsv'
  else
    secret_json | jq -r '[.username, .password, .host] | @tsv'
  fi
}

precheck() {
  local user pw host
  IFS=$'\t' read -r user pw host <<<"$(app_creds)"
  echo "secret ${SECRET_MODE}:$([[ $SECRET_MODE == k8s ]] && echo "$K8S_NS/$K8S_SECRET" || echo "$SECRET_ID"): host(now)=$host → target=$NEW_HOST:$NEW_PORT user=$user"
  if PGPASSWORD="$pw" psql "host=$NEW_HOST port=$NEW_PORT dbname=${DB_NAME:-app} user=$user sslmode=${DR_PGSSLMODE:-require} connect_timeout=5 application_name=dr-precheck" \
       -XAtqc "select 'login OK as ' || current_user || ', in_recovery=' || pg_is_in_recovery()"; then
    return 0
  fi
  echo "LOGIN FAILED on $TARGET_DB with the current secret password."
  echo "Restored DBs keep passwords as of the restore point. Fix with: $0 fix-password (needs MASTER_SECRET_ID)"
  return 1
}

fix_password() {
  : "${MASTER_SECRET_ID:?MASTER_SECRET_ID (master user secret) required}"
  local m user pw
  IFS=$'\t' read -r user pw _ <<<"$(app_creds)"; m="$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" secretsmanager get-secret-value --secret-id "$MASTER_SECRET_ID" --query SecretString --output text)"
  # psql variables keep the password out of argv/ps output. NOTE: with log_statement=ddl/all the statement can reach the
  # PostgreSQL log — rotate the secret after stabilisation (CP03-S05).
  PGPASSWORD="$(jq -r .password <<<"$m")" psql "host=$NEW_HOST port=$NEW_PORT dbname=${DB_NAME:-app} user=$(jq -r .username <<<"$m") sslmode=${DR_PGSSLMODE:-require}" \
    -v ON_ERROR_STOP=1 -v role="$user" -v pw="$pw" -Xq <<'SQL'
ALTER ROLE :"role" WITH PASSWORD :'pw';
SQL
  dr_mark FIX_PASSWORD "role reset on ${TARGET_DB}"
  precheck
}

wait_k8s_secret_host() { # every key in K8S_HOST_KEY must hold the new host
  local want="$1" deadline=$(( $(date +%s) + 180 )) got=""
  $K annotate externalsecret "$K8S_SECRET" force-sync="$(date +%s)" --overwrite >/dev/null
  while (( $(date +%s) < deadline )); do
    got="$($K get secret "$K8S_SECRET" -o json | jq -r --arg ks "${K8S_HOST_KEY:-DB_HOST}" '[($ks | split(","))[] as $k | (.data[$k] // "" | @base64d)] | unique | join(",")')"
    [[ "$got" == "$want" ]] && { echo "K8s Secret $K8S_SECRET ${K8S_HOST_KEY:-DB_HOST}=$got (synced)"; return 0; }
    sleep 5
  done
  echo "TIMEOUT: K8s Secret $K8S_SECRET hosts='$got' != '$want' — check ESO controller / ExternalSecret status (and its template maps host to every key)"; return 1
}

apply_k8s() {
  local id="${CUTOVER_ID:-$DR_ID}"
  "$HERE/dr-eks-rollout.sh" snapshot-generations "$K8S_SECRET"
  "${EP[@]}" set --host "$NEW_HOST" ${K8S_PORT_KEY:+--port "${NEW_PORT:-5432}"} --db-id "$TARGET_DB" --from-db-id "${OLD_DB:-}" --id "$id" \
    | tee "$DR_EVIDENCE_DIR/k8s/endpoint-change-${id}.txt"
  dr_mark "SECRET_UPDATED:${K8S_NS}/${K8S_SECRET}" "id=${id} keys=${K8S_HOST_KEY} host=${NEW_HOST} db=${TARGET_DB}"
  dr_mark T6 "k8s secret ${K8S_SECRET} → ${TARGET_DB} (id ${id})"
  "$HERE/dr-eks-rollout.sh" wait "$K8S_SECRET"
  dr_mark T7 "consumers of ${K8S_SECRET} rolled"
  echo "CUTOVER DONE: $K8S_NS/$K8S_SECRET → $TARGET_DB ($NEW_HOST) id=$id. Undo: $0 rollback · later failback: $0 failback $id"
}

revert_k8s() { # rollback | failback <ref>
  local kind="$1" ref="${2:-}" id
  id="${CUTOVER_ID:-${DR_ID}-${kind}}"
  "$HERE/dr-eks-rollout.sh" snapshot-generations "$K8S_SECRET"
  if [[ "$kind" == rollback ]]; then "${EP[@]}" rollback --id "$id"; else "${EP[@]}" failback --to "$ref" --id "$id"; fi \
    | tee "$DR_EVIDENCE_DIR/k8s/endpoint-change-${id}.txt"
  dr_mark "SECRET_${kind^^}:${K8S_NS}/${K8S_SECRET}" "id=${id}${ref:+ ref=${ref}}"
  "$HERE/dr-eks-rollout.sh" wait "$K8S_SECRET"
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
  ver="$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" secretsmanager put-secret-value --secret-id "$SECRET_ID" --secret-string "$new" --query VersionId --output text)"
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
  aws --profile "$AWS_PROFILE" --region "$AWS_REGION" secretsmanager update-secret-version-stage --secret-id "$SECRET_ID" --version-stage AWSCURRENT \
    --move-to-version-id "$prev" --remove-from-version-id "$cur"
  host="$(secret_json | jq -r .host)"
  dr_mark "SECRET_ROLLBACK:${SECRET_ID}" "AWSCURRENT=${prev} host=${host}"
  "$HERE/dr-eks-rollout.sh" snapshot-generations "$K8S_SECRET"
  wait_k8s_secret_host "$host"
  "$HERE/dr-eks-rollout.sh" wait "$K8S_SECRET"
}

case "$CMD" in
  precheck)     precheck ;;
  fix-password) dr_confirm "reset app password on $TARGET_DB" && fix_password ;;
  apply)        precheck && dr_confirm "point $K8S_SECRET at $TARGET_DB (pods will restart)" \
                  && if [[ "$SECRET_MODE" == k8s ]]; then apply_k8s; else apply; fi ;;
  rollback)     dr_confirm "roll back $K8S_SECRET" && if [[ "$SECRET_MODE" == k8s ]]; then revert_k8s rollback; else rollback; fi ;;
  failback)     [[ "$SECRET_MODE" == k8s ]] || { echo "failback <id> needs SECRET_MODE=k8s (eso: run apply with TARGET_DB=<original instance>)"; exit 2; }
                dr_confirm "fail back $K8S_SECRET to the endpoint before ${2:?change id, see: $0 history}" && revert_k8s failback "$2" ;;
  history)      "${EP[@]}" history ;;
  show)         "${EP[@]}" show ;;
  *) echo "usage: $0 {precheck|fix-password|apply|rollback|failback <id>|history|show}"; exit 2 ;;
esac
