#!/usr/bin/env bash
set -euo pipefail
set +x
failback_data_policy() {
  case "$1" in
    RECONCILED) printf '%s\n' reconciled ;;
    ACCEPT_LOCAL_DATA_LOSS)
      [[ "${DR_ENV:-}" == local ]] || { echo 'REFUSED: data-loss waiver is local-test-only.' >&2; return 1; }
      printf '%s\n' local-test-data-loss-accepted ;;
    *) echo 'Failback cancelled: data handling was not confirmed.' >&2; return 1 ;;
  esac
}
inputs=(FENCE SNAPSHOT_ID T0_AT OLD_DB RESTORED_DB BAD_TS RESTORE_TS RESTORE_MODE E2E_REF DR_ID DR_SELECTOR DR_DB_ACCESS APP_OWNER APP_DB_DESTINATION DATA_OWNER DATA_ACCEPTANCE_REF RESTORE_POINT_REF)
saved_names=() saved_values=()
for name in "${inputs[@]}"; do
  if [[ -v "$name" ]]; then
    saved_names+=("$name"); saved_values+=("${!name}")
  fi
done
demo_selector="${DR_SELECTOR:-app in (app-d,app-e)}"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_ENDPOINT_URL
unset SECRET_MODE
# shellcheck source=/dev/null
source /workspace/tests/local/.state/local.env
if [[ -f /workspace/tests/local/.state/normalization.env ]]; then
  source /workspace/tests/local/.state/normalization.env
fi
for index in "${!saved_names[@]}"; do
  export "${saved_names[$index]}=${saved_values[$index]}"
done
[[ "$DR_ENV" == local && "$AWS_PROFILE" == dr-local && "$ACCOUNT_ID" == 000000000000 && "$EKS_CONTEXT" == dr-local ]] \
  || { echo 'REFUSED: this demo requires the generated local fixture profile.' >&2; exit 2; }
[[ "${DR_ENDPOINT_MAP:-}" == /workspace/tests/local/.state/endpoint-map ]] \
  || { echo 'REFUSED: the local fixture endpoint map is required.' >&2; exit 2; }
unset DR_ASSUME_YES DR_RUN_AUTO_NO CUTOVER_SECRET K8S_SECRET_RO CUTOVER_ID DR_GUARD_OK
[[ "${DR_RUN_GATES:-}" != auto ]] || { echo 'REFUSED: demo approvals must be entered by a person.' >&2; exit 2; }
for argument in "$@"; do
  [[ "$argument" != --auto-gates ]] || { echo 'REFUSED: demo approvals must be entered by a person.' >&2; exit 2; }
done
export SECRET_MODE=k8s K8S_SECRET=app-db-direct K8S_HOST_KEY=POSTGRES_DB_HOST1,POSTGRES_DB_HOST2
export K8S_PORT_KEY=POSTGRES_DB_PORT K8S_USER_KEY=POSTGRES_DB_USER K8S_PASSWORD_KEY=POSTGRES_DB_PASSWORD
export DR_DB_ACCESS="${DR_DB_ACCESS:-none}"
[[ "$DR_DB_ACCESS" == none || "$DR_DB_ACCESS" == readonly ]] || { echo 'DR_DB_ACCESS must be none or readonly'; exit 2; }
if [[ "$DR_DB_ACCESS" == none ]]; then
  export K8S_SECRET=app-db-endpoint RESTART_UNANNOTATED=false
  [[ -f /workspace/tests/local/.state/operator-kubeconfig ]] \
    || { echo 'REFUSED: app/platform owner must run iac/local/prepare-operator.sh in the tools container first.' >&2; exit 2; }
  export KUBECONFIG=/workspace/tests/local/.state/operator-kubeconfig
  identity="$(kubectl --context "$EKS_CONTEXT" auth whoami -o json | jq -er '.status.userInfo.username')"
  [[ "$identity" == system:serviceaccount:app:dr-operator ]] \
    || { echo 'REFUSED: operator mode must use the dr-operator ServiceAccount, not the platform/admin identity.' >&2; exit 2; }
else
  if kubectl --context "$EKS_CONTEXT" -n app get deployment app-d -o json 2>/dev/null |
    jq -e 'any(.spec.template.spec.containers[].envFrom[]?; .secretRef.name == "app-db-endpoint")' >/dev/null; then
    echo 'REFUSED: the split-endpoint fixture requires operator mode; legacy SQL drills require the legacy fixture configuration.' >&2; exit 2
  fi
fi
export DR_SELECTOR="$demo_selector"
cd /workspace
if [[ "${1:-}" == failback ]]; then
  requested_ref="${2:-}"
  [[ $# -le 2 && ( -z "$requested_ref" || "$requested_ref" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$ ) ]] \
    || { echo 'Usage: dr.sh failback [recorded-change-id]' >&2; exit 2; }
  [[ -t 0 && -t 1 ]] || { echo 'REFUSED: failback needs an interactive terminal.' >&2; exit 2; }
  unset DR_ID DR_EVIDENCE_DIR DR_TIMELINE DR_AUDIT_LOG DR_ACTOR TARGET_DSN OLD_DSN
  source automation/scripts/dr-lib.sh
  dr_guard || exit 2
  endpoint=(automation/scripts/k8s-secret-endpoint.sh --context "$EKS_CONTEXT" -n "$K8S_NS" \
    -s "$K8S_SECRET" -k "$K8S_HOST_KEY" --port-key "$K8S_PORT_KEY")
  ledger="$(kubectl --context "$EKS_CONTEXT" --request-timeout=20s -n "$K8S_NS" \
    get configmap "dr-endpoint-ledger-$K8S_SECRET" -o json)"

  if [[ -z "$requested_ref" ]]; then
    mapfile -t candidates < <(jq -r --arg secret "$K8S_NS/$K8S_SECRET" --arg keys "$K8S_HOST_KEY" '
      [.data[]? | (try fromjson catch empty)
       | select(.secret == $secret
         and (.id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$"))
         and (.keys | keys | sort) == ($keys | split(",") | sort)
         and ([.keys[].from] | unique | length) == 1
         and all(.keys[].from; type == "string" and length > 0)
         and (.fromDb | type == "string" and length > 0 and . != "unknown"))]
      | sort_by(.at // "") | reverse[]
      | [.id, .at, .fromDb, .toDb, .keys["POSTGRES_DB_HOST1"].from] | @tsv
    ' <<<"$ledger")
    ((${#candidates[@]} > 0)) || { echo 'REFUSED: no eligible endpoint changes found in the ledger.' >&2; exit 2; }
    echo 'Select the recorded endpoint change to fail back from:'
    for index in "${!candidates[@]}"; do
      IFS=$'\t' read -r candidate_id at from_db to_db old_host <<<"${candidates[$index]}"
      printf '  %2d) %s | %s -> %s | host %s | %s\n' "$((index + 1))" "$candidate_id" "$from_db" "$to_db" "$old_host" "$at"
    done
    read -r -p 'Selection [1 = newest, q = cancel]: ' selection </dev/tty
    [[ "$selection" != q && "$selection" != Q ]] || { echo 'Failback cancelled.'; exit 2; }
    selection="${selection:-1}"
    [[ "$selection" =~ ^[0-9]+$ ]] || { echo 'REFUSED: enter a listed number or q.' >&2; exit 2; }
    (( selection >= 1 && selection <= ${#candidates[@]} )) || { echo 'REFUSED: selection is out of range.' >&2; exit 2; }
    IFS=$'\t' read -r requested_ref at from_db to_db old_host <<<"${candidates[$((selection - 1))]}"
    printf 'Selected %s: %s -> %s (prior host %s)\n' "$requested_ref" "$from_db" "$to_db" "$old_host"
  else
    "${endpoint[@]}" history
  fi

  record="$(jq -ce --arg ref "$requested_ref" '
    [.data[] | fromjson | select(.id == $ref)] |
    if length == 1 then .[0] else error("change ID missing or duplicated in ledger") end
  ' <<<"$ledger")" || exit 2
  jq -e --arg keys "$K8S_HOST_KEY" --arg secret "$K8S_NS/$K8S_SECRET" '
    .secret == $secret and (.keys | keys | sort) == ($keys | split(",") | sort) and
    ([.keys[].from] | unique | length) == 1 and
    all(.keys[].from; type == "string" and length > 0) and
    (.fromDb | type == "string" and length > 0 and . != "unknown")
  ' <<<"$record" >/dev/null || { echo 'REFUSED: ledger target is unknown, mixed, or uses different host keys.' >&2; exit 2; }
  TARGET_DB="$(jq -r .fromDb <<<"$record")"
  export TARGET_DB
  [[ "$TARGET_DB" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || { echo 'REFUSED: invalid recorded database ID.' >&2; exit 2; }
  target_host="$(jq -r '.keys | to_entries[0].value.from' <<<"$record")"
  read -r mapped_host mapped_port <<<"$(dr_endpoint "$TARGET_DB")"
  [[ "$target_host" == "$mapped_host" && -n "$mapped_port" ]] \
    || { echo 'REFUSED: recorded endpoint does not match the local target database.' >&2; exit 2; }
  secret="$(kubectl --context "$EKS_CONTEXT" --request-timeout=20s -n "$K8S_NS" get secret "$K8S_SECRET" -o json)"
  target_port="$(jq -r '.port.from // empty' <<<"$record")"
  if [[ -z "$target_port" ]]; then
    target_port="$(jq -r --arg key "$K8S_PORT_KEY" '.data[$key] // "" | @base64d' <<<"$secret")"
  fi
  [[ "$target_port" == "$mapped_port" ]] || { echo 'REFUSED: effective failback port does not match the local target.' >&2; exit 2; }
  if [[ "$DR_DB_ACCESS" != none ]]; then
    app_user="$(jq -r --arg key "$K8S_USER_KEY" '.data[$key] // "" | @base64d' <<<"$secret")"
    app_password="$(jq -r --arg key "$K8S_PASSWORD_KEY" '.data[$key] // "" | @base64d' <<<"$secret")"
  fi
  unset secret
  [[ "$DR_DB_ACCESS" == none || ( "$app_user" == app_user && -n "$app_password" && "$DB_NAME" == app ) ]] \
    || { echo 'REFUSED: expected local app_user credentials and app database.' >&2; exit 2; }
  fence_help() {
    local state evidence_dir found=0
    for state in /workspace/evidence/*/db/"fence-$TARGET_DB".readonly /workspace/evidence/*/db/"fence-$TARGET_DB".sgs.json; do
      [[ -f "$state" ]] || continue
      evidence_dir="${state%/db/*}"; found=1
      printf 'Fence state: %s\n' "$state" >&2
      printf 'After reviewing reconciliation and approving removal, restore using the ORIGINAL evidence directory:\n' >&2
      printf 'DR_EVIDENCE_DIR=%q DR_TIMELINE=%q automation/scripts/dr-fence-instance.sh restore %q\n' \
        "$evidence_dir" "$evidence_dir/timeline.jsonl" "$TARGET_DB" >&2
    done
    if [[ "$found" == 0 ]]; then
      echo 'No saved local fence state found. Locate the original fencing evidence before any manual restore; do not use a new failback directory.' >&2
    fi
    echo 'Fence files may remain after restore. No fence removal or data reconciliation was performed.' >&2
  }
  verify_target() {
    if [[ "$DR_DB_ACCESS" == none ]]; then
      DR_EVIDENCE_DIR=/workspace/tests/local/.state/evidence/adhoc automation/scripts/dr-secret-cutover.sh check-target || return 1
      echo 'API target availability verified; app-owner connectivity/business E2E remains required after failback.'
      return 0
    fi
    local settings probe
    if ! settings="$(PGPASSWORD="$app_password" PGSSLMODE="${DR_PGSSLMODE:-disable}" PGCONNECT_TIMEOUT=5 \
      PGAPPNAME=dr-failback-check psql -h "$target_host" -p "$target_port" -U "$app_user" -d "$DB_NAME" -XAtq -v ON_ERROR_STOP=1 \
      -c "SELECT pg_is_in_recovery(), current_setting('default_transaction_read_only'), current_setting('transaction_read_only'),
        COALESCE((SELECT split_part(setting, '=', 2) FROM pg_db_role_setting settings,
          unnest(settings.setconfig) setting WHERE settings.setdatabase = (SELECT oid FROM pg_database WHERE datname = current_database())
          AND settings.setrole = 0 AND setting LIKE 'default_transaction_read_only=%'), 'off');" 2>/dev/null)"; then
      echo 'REFUSED: cannot verify app_user access to the recorded target (login, reachability, or quarantine fence).' >&2
      fence_help; return 1
    fi
    if [[ "$settings" != 'f|off|off|off' ]]; then
      printf 'REFUSED: target recovery/default/session/database read-only settings: %s\n' "$settings" >&2
      fence_help; return 1
    fi
    if ! probe="$(PGPASSWORD="$app_password" PGSSLMODE="${DR_PGSSLMODE:-disable}" PGCONNECT_TIMEOUT=5 \
      PGAPPNAME=dr-failback-check psql -h "$target_host" -p "$target_port" -U "$app_user" -d "$DB_NAME" -XAtq -v ON_ERROR_STOP=1 \
      -c "BEGIN READ ONLY; SET LOCAL statement_timeout = '5s';
        SELECT 'READ_OK' FROM public.orders LIMIT 1; COMMIT;" 2>/dev/null)" \
      || [[ "$probe" != READ_OK ]]; then
      echo 'REFUSED: app_user read probe failed; target readability is not verified.' >&2
      fence_help; return 1
    fi
    echo 'Read-only database checks passed; committed business writes require separate application E2E.'
  }
  verify_target || exit 2
  echo "Endpoint failback only: $K8S_NS/$K8S_SECRET -> $TARGET_DB (before change $requested_ref)."
  echo 'Writes made on the restored database are NOT copied back. Reconcile them manually before continuing.'
  echo 'For disposable local test data only, ACCEPT_LOCAL_DATA_LOSS leaves restored-side writes behind; it does not mean reconciled.'
  read -r -p 'Data handling [RECONCILED / ACCEPT_LOCAL_DATA_LOSS]> ' reconciliation
  data_policy="$(failback_data_policy "$reconciliation")" || exit 2
  read -r -p 'Type GO to approve this endpoint failback: ' answer
  [[ "$answer" == GO ]] || exit 2
  read -r -p 'Approver name(s): ' approver
  [[ "$approver" =~ [^[:space:]] && ! "${approver^^}" =~ ^(GO|NO|RECONCILED|ACCEPT_LOCAL_DATA_LOSS)$ ]] \
    || { echo 'REFUSED: enter a person name, not a decision token.' >&2; exit 2; }
  verify_target || exit 2
  unset app_password
  current_record="$(kubectl --context "$EKS_CONTEXT" --request-timeout=20s -n "$K8S_NS" \
    get configmap "dr-endpoint-ledger-$K8S_SECRET" -o json | jq -ce --arg ref "$requested_ref" \
      '[.data[] | fromjson | select(.id == $ref)] | if length == 1 then .[0] else error("ledger changed") end')"
  [[ "$(jq -cS . <<<"$record")" == "$(jq -cS . <<<"$current_record")" ]] \
    || { echo 'REFUSED: ledger record changed during verification.' >&2; exit 2; }
  DR_ID="DR-local-failback-$(date -u +%Y%m%d%H%M%S)-$$"
  export DR_ID
  export DR_EVIDENCE_DIR="/workspace/evidence/$DR_ID"
  dr_init FB-S3S4
  printf '%s\n' "$record" > "$DR_EVIDENCE_DIR/k8s/failback-reference.json"
  printf 'reference: %s\ntarget: %s\ndata_policy: %s\nconfirmation: %s\nanswer: %s\napprovers: %s\nat: %s\n' \
    "$requested_ref" "$TARGET_DB" "$data_policy" "$reconciliation" "$answer" "$approver" "$(date -u +%FT%TZ)" > "$DR_EVIDENCE_DIR/approvals/endpoint-failback.txt"
  dr_mark DECISION "endpoint failback GO by $approver; data_policy=$data_policy; ref=$requested_ref target=$TARGET_DB"
  automation/scripts/dr-secret-cutover.sh failback "$requested_ref"
  if ! automation/scripts/dr-eks-rollout.sh check; then
    automation/scripts/dr-eks-rollout.sh restart-stale
    automation/scripts/dr-eks-rollout.sh check
  fi
  if [[ "$DR_DB_ACCESS" == none ]]; then
    automation/scripts/dr-secret-cutover.sh verify-routing
    dr_mark ROUTING_VERIFIED "failback target=$TARGET_DB; operator performed no SQL"
    echo "App owner must independently verify connectivity to $TARGET_DB and the business E2E before failback is declared verified."
    read -r -p 'App owner name> ' app_owner </dev/tty
    read -r -p "Did you verify connectivity and a successful business transaction on $TARGET_DB? [yes/no]> " app_destination_confirmed </dev/tty
    [[ "${app_destination_confirmed,,}" == yes || "${app_destination_confirmed,,}" == y ]] \
      || { echo 'Failback endpoint changed but destination is not confirmed; do not stop the restored DB.' >&2; exit 2; }
    app_destination="$TARGET_DB"
    read -r -p 'New failback E2E evidence reference> ' app_evidence </dev/tty
    [[ "$app_owner" =~ [^[:space:]] && ! "${app_owner^^}" =~ ^(GO|NO|RECONCILED|ACCEPT_LOCAL_DATA_LOSS)$ &&
       "$app_destination" == "$TARGET_DB" && "$app_evidence" =~ [^[:space:]] ]] \
      || { echo 'Failback endpoint changed but app-owner verification is incomplete; do not stop the restored DB.' >&2; exit 2; }
    read -r -p 'App owner: type GO to attest connectivity and business E2E passed> ' app_decision </dev/tty
    [[ "$app_decision" == GO ]] \
      || { echo 'Failback endpoint changed but app-owner approval is missing; do not stop the restored DB.' >&2; exit 2; }
    automation/scripts/dr-secret-cutover.sh verify-routing
    automation/scripts/dr-eks-rollout.sh check
    printf 'owner: %s\ntarget: %s\nevidence: %s\nanswer: %s\noperator_sql: none\n' \
      "$app_owner" "$app_destination" "$app_evidence" "$app_decision" > "$DR_EVIDENCE_DIR/approvals/app-owner-e2e.txt"
    dr_mark T9 "failback app-owner=$app_owner target=$TARGET_DB evidence=$app_evidence; operator performed no SQL"
    printf '# Local Failback\n\nDatabase access: none (no operator SQL).\n\nTarget: %s\n\nData policy: %s\n\nApp owner: %s\n\nE2E evidence: %s\n' \
      "$TARGET_DB" "$data_policy" "$app_owner" "$app_evidence" > "$DR_EVIDENCE_DIR/run-report.md"
  fi
else
  if [[ "${1:-}" == S3 ]]; then
    echo "Local walkthrough snapshots are simulated fixtures; automated entries are not real RDS backups."
  fi
  exec automation/scripts/dr-run.sh "$@"
fi