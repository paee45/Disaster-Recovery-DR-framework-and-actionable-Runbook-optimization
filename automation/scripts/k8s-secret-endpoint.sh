#!/usr/bin/env bash
# k8s-secret-endpoint.sh — standalone tool: change the DB endpoint in a Kubernetes Secret DIRECTLY (no ESO), with a
# ledger so every change has an ID and any earlier state can be restored by that ID. Usable by hand, from the runbooks,
# or from dr-secret-cutover.sh (SECRET_MODE=k8s). Reloader (annotation on the workloads) restarts the pods.
#
#   k8s-secret-endpoint.sh [opts] show                     current value of every host key + last cutover
#   k8s-secret-endpoint.sh [opts] history                  every recorded change, oldest first
#   k8s-secret-endpoint.sh [opts] set --host H --db-id DB --id ID [--port P] [--from-db-id OLD] [--dry-run]
#                                                          all host keys → H (one atomic patch), ledger entry "cutover"
#   k8s-secret-endpoint.sh [opts] rollback --id ID         undo the LATEST change (restore its "from" values)
#   k8s-secret-endpoint.sh [opts] failback --to REF --id ID
#                                                          restore the endpoint that was in place BEFORE change REF
# Options (or env):  --context CTX (EKS_CONTEXT, mandatory)   -n NS (K8S_NS)   -s SECRET (K8S_SECRET)
#                    -k KEY1,KEY2,... (K8S_HOST_KEY, e.g. POSTGRES_DB_HOST1,POSTGRES_DB_HOST2)
#                    --port-key KEY (K8S_PORT_KEY, optional)   --expect-env ENV (DR_ENV)   --force   --allow-eso-owned
#
# Change IDs: use the DR id, e.g. DR-20261004-0930-uat-S3 (cutover) and DR-20261005-1000-uat-FB-S3S4 (failback).
# Ledger:     ConfigMap dr-endpoint-ledger-<secret> (same namespace), one key per change "<seq>.<id>" →
#             {seq,id,type,ref,at,actor,ticket,keys:{K:{from,to}},port:{from,to},fromDb,toDb}
# Secret annotations: dr.example.com/cutover-id, /endpoint-db-id, /endpoint-host, /previous-cutover-id, /ledger
# Safety: refuses a Secret owned by an ExternalSecret (ESO would revert the change) unless --allow-eso-owned;
#         rollback refuses if the Secret no longer holds the values the last change wrote (someone changed it) unless --force.
set -euo pipefail
if (( BASH_VERSINFO[0] < 4 )); then echo "ERROR: needs bash>=4 (macOS: brew install bash)" >&2; exit 1; fi

CTX="${EKS_CONTEXT:-}"; NS="${K8S_NS:-}"; SECRET="${K8S_SECRET:-}"; KEYS="${K8S_HOST_KEY:-}"; PORT_KEY="${K8S_PORT_KEY:-}"
EXPECT_ENV="${DR_ENV:-}"; HOST=""; PORT=""; DB_ID=""; FROM_DB=""; ID=""; REF=""; DRY=0; FORCE=0; ALLOW_ESO=0
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) CTX="$2"; shift 2 ;;
    -n|--namespace) NS="$2"; shift 2 ;;
    -s|--secret) SECRET="$2"; shift 2 ;;
    -k|--keys) KEYS="$2"; shift 2 ;;
    --port-key) PORT_KEY="$2"; shift 2 ;;
    --expect-env) EXPECT_ENV="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --db-id) DB_ID="$2"; shift 2 ;;
    --from-db-id) FROM_DB="$2"; shift 2 ;;
    --id) ID="$2"; shift 2 ;;
    --to) REF="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --force) FORCE=1; shift ;;
    --allow-eso-owned) ALLOW_ESO=1; shift ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
set -- "${ARGS[@]}"
CMD="${1:-}"
[[ -n "$CTX" ]] || { echo "ERROR: --context (or EKS_CONTEXT) is mandatory — the current context is never used" >&2; exit 2; }
[[ -n "$NS" && -n "$SECRET" && -n "$KEYS" ]] || { echo "ERROR: -n, -s and -k (host keys) are mandatory" >&2; exit 2; }
IFS=',' read -ra HK <<<"${KEYS// /}"
K=(kubectl --context "$CTX" --request-timeout=20s -n "$NS")
LEDGER="dr-endpoint-ledger-${SECRET}"
ID_RE='^[A-Za-z0-9][A-Za-z0-9._-]{2,80}$'

if [[ -n "$EXPECT_ENV" && "${REQUIRE_CLUSTER_IDENTITY:-true}" == "true" ]]; then
  got="$(kubectl --context "$CTX" --request-timeout=10s -n kube-system get configmap dr-cluster-identity -o jsonpath='{.data.env}' 2>/dev/null || true)"
  [[ "$got" == "$EXPECT_ENV" ]] || { echo "REFUSED: context '$CTX' identifies as env='${got:-?}', expected '$EXPECT_ENV'" >&2; exit 2; }
fi

b64d() { base64 -d 2>/dev/null || true; }
secret_json() { "${K[@]}" get secret "$SECRET" -o json; }
value_of() { jq -r --arg k "$2" '.data[$k] // empty' <<<"$1" | b64d; }   # <secret-json> <key>
ledger_json() { "${K[@]}" get configmap "$LEDGER" -o json 2>/dev/null || echo '{"data":{}}'; }
entries() { ledger_json | jq -c '[.data // {} | to_entries[] | .value | fromjson] | sort_by(.seq)'; }
actor() { echo "${DR_ACTOR:-$(kubectl --context "$CTX" auth whoami -o jsonpath='{.status.userInfo.username}' 2>/dev/null || id -un)}"; }

guard_owner() {
  local owner; owner="$(jq -r '[.metadata.ownerReferences[]? | select(.kind == "ExternalSecret") | .name] | join(",")' <<<"$1")"
  if [[ -n "$owner" && "$ALLOW_ESO" != 1 ]]; then
    echo "REFUSED: Secret $NS/$SECRET is owned by ExternalSecret '$owner' — ESO would overwrite a direct change." >&2
    echo "         Use SECRET_MODE=eso (update Secrets Manager), or --allow-eso-owned if ESO sync is paused." >&2
    exit 2
  fi
}

# change <type> <id> <ref> <to-json {KEY:value}> <to-port> <to-db> <from-db>
change() {
  local type="$1" id="$2" ref="$3" to="$4" to_port="$5" to_db="$6" from_db="$7" s cur from fport seq entry patch k
  [[ "$id" =~ $ID_RE ]] || { echo "ERROR: --id '$id' must match $ID_RE (e.g. DR-20261004-0930-uat-S3)" >&2; exit 2; }
  s="$(secret_json)"; guard_owner "$s"
  from="{}"; for k in "${HK[@]}"; do
    cur="$(value_of "$s" "$k")"; [[ -n "$cur" ]] || { echo "ERROR: key $k not in Secret $NS/$SECRET" >&2; exit 2; }
    from="$(jq -c --arg k "$k" --arg v "$cur" '. + {($k): $v}' <<<"$from")"
  done
  fport=""; [[ -n "$PORT_KEY" ]] && fport="$(value_of "$s" "$PORT_KEY")"
  # the DB the Secret points at NOW = what the last recorded change wrote; --from-db-id is only used before any change
  local rec; rec="$(jq -r '.metadata.annotations["dr.example.com/endpoint-db-id"] // empty' <<<"$s")"
  if [[ -n "$rec" ]]; then
    [[ -n "$from_db" && "$from_db" != "$rec" ]] && echo "NOTE: --from-db-id '$from_db' ignored — the Secret records it currently points at '$rec'"
    from_db="$rec"
  fi
  if jq -e --argjson f "$from" 'to_entries | all(.value == $f[.key])' <<<"$to" >/dev/null && [[ "$FORCE" != 1 ]]; then
    echo "NO CHANGE: every key already has the target value ($(jq -c . <<<"$to")) — nothing written (use --force to record anyway)"; return 0; fi
  seq="$(entries | jq 'map(.seq) | max // 0 | . + 1')"
  entry="$(jq -cn --argjson seq "$seq" --arg id "$id" --arg type "$type" --arg ref "$ref" --arg at "$(date -u +%FT%TZ)" \
      --arg actor "$(actor)" --arg ticket "${DR_TICKET:-}" --arg secret "$NS/$SECRET" --argjson from "$from" --argjson to "$to" \
      --arg fp "$fport" --arg tp "$to_port" --arg fdb "${from_db:-unknown}" --arg tdb "${to_db:-unknown}" '
      {seq:$seq, id:$id, type:$type, ref:(if $ref == "" then null else $ref end), at:$at, actor:$actor,
       ticket:(if $ticket == "" then null else $ticket end), secret:$secret,
       keys:($to | with_entries(.value = {from: $from[.key], to: .value})),
       port:(if $tp == "" then null else {from:$fp, to:$tp} end), fromDb:$fdb, toDb:$tdb}')"
  echo "change #$seq $type $id${ref:+ (ref $ref)}:"; jq -r '.keys | to_entries[] | "  \(.key): \(.value.from) → \(.value.to)"' <<<"$entry"
  echo "  db: $(jq -r '"\(.fromDb) → \(.toDb)"' <<<"$entry")"
  if (( DRY )); then echo "DRY-RUN: nothing written"; return 0; fi
  # 1) ledger first (intent is recorded even if the patch fails); 2) ONE atomic patch of data + annotations (one reload)
  "${K[@]}" get configmap "$LEDGER" >/dev/null 2>&1 \
    || "${K[@]}" create configmap "$LEDGER" >/dev/null
  "${K[@]}" label configmap "$LEDGER" dr.example.com/ledger=true "dr.example.com/secret=$SECRET" --overwrite >/dev/null
  "${K[@]}" patch configmap "$LEDGER" --type merge -p "$(jq -cn --arg k "$(printf '%04d' "$seq").$id" --arg v "$entry" '{data: {($k): $v}}')" >/dev/null
  patch="$(jq -cn --argjson to "$to" --arg pk "$PORT_KEY" --arg tp "$to_port" --arg id "$id" --arg db "${to_db:-unknown}" \
      --arg host "$(jq -r 'to_entries[0].value' <<<"$to")" --arg prev "$(jq -r '.metadata.annotations["dr.example.com/cutover-id"] // ""' <<<"$s")" \
      --arg led "configmap/$LEDGER" '
      {data: (($to | with_entries(.value |= @base64)) + (if $pk != "" and $tp != "" then {($pk): ($tp | @base64)} else {} end)),
       metadata: {annotations: {"dr.example.com/cutover-id": $id, "dr.example.com/endpoint-db-id": $db,
         "dr.example.com/endpoint-host": $host, "dr.example.com/previous-cutover-id": $prev, "dr.example.com/ledger": $led}}}')"
  "${K[@]}" patch secret "$SECRET" --type merge -p "$patch" >/dev/null \
    || { echo "ERROR: Secret patch failed AFTER the ledger entry was written — re-run or fix by hand; entry: $entry" >&2; exit 1; }
  [[ -n "${DR_EVIDENCE_DIR:-}" ]] && { mkdir -p "$DR_EVIDENCE_DIR/k8s"; echo "$entry" >> "$DR_EVIDENCE_DIR/k8s/endpoint-ledger-${SECRET}.jsonl"; }
  echo "APPLIED: Secret $NS/$SECRET → $(jq -r 'to_entries[0].value' <<<"$to") (id $id). Reloader restarts the annotated workloads."
}

# the ledger entry being reverted must have been written with the SAME key list as this call (-k) — otherwise a revert
# would silently change keys the caller did not name (or leave some out)
same_keys() { # <entry-json>
  [[ "$FORCE" == 1 ]] && return 0
  local have want; have="$(printf '%s\n' "${HK[@]}" | sort | paste -sd, -)"; want="$(jq -r '.keys | keys | sort | join(",")' <<<"$1")"
  [[ "$have" == "$want" ]] || { echo "REFUSED: that change #$(jq .seq <<<"$1") ($(jq -r .id <<<"$1")) was written for keys [$want], this call names [$have] — use the same -k/K8S_HOST_KEY (or --force)" >&2; exit 2; }
}

all_keys_to() { local h="$1" o="{}" k; for k in "${HK[@]}"; do o="$(jq -c --arg k "$k" --arg v "$h" '. + {($k): $v}' <<<"$o")"; done; echo "$o"; }

case "$CMD" in
  show)
    s="$(secret_json)"
    echo "secret $NS/$SECRET (context $CTX)"
    for k in "${HK[@]}"; do printf '  %-28s %s\n' "$k" "$(value_of "$s" "$k")"; done
    [[ -n "$PORT_KEY" ]] && printf '  %-28s %s\n' "$PORT_KEY" "$(value_of "$s" "$PORT_KEY")"
    jq -r '.metadata.annotations // {} | "  cutover-id=\(.["dr.example.com/cutover-id"] // "-")  db=\(.["dr.example.com/endpoint-db-id"] // "-")  previous=\(.["dr.example.com/previous-cutover-id"] // "-")"' <<<"$s"
    jq -r 'if [.metadata.ownerReferences[]? | select(.kind=="ExternalSecret")] | length > 0 then "  managed by ESO (direct changes would be reverted)" else "  not managed by ESO (direct changes are safe)" end' <<<"$s"
    ;;
  history)
    entries | jq -r '.[] | "#\(.seq)  \(.at)  \(.type | ascii_upcase | .[0:8])  \(.id)\(if .ref then "  (ref \(.ref))" else "" end)  \(.fromDb) → \(.toDb)  \([.keys | to_entries[] | "\(.key)=\(.value.to)"] | join(" "))  by \(.actor)"'
    ;;
  set)
    [[ -n "$HOST" && -n "$DB_ID" && -n "$ID" ]] || { echo "usage: set --host H --db-id DB --id ID [--port P] [--from-db-id OLD]" >&2; exit 2; }
    change cutover "$ID" "" "$(all_keys_to "$HOST")" "$PORT" "$DB_ID" "$FROM_DB"
    ;;
  rollback)
    [[ -n "$ID" ]] || { echo "usage: rollback --id ID" >&2; exit 2; }
    last="$(entries | jq -c 'last // empty')"; [[ -n "$last" ]] || { echo "ERROR: ledger $LEDGER is empty — nothing to roll back" >&2; exit 2; }
    same_keys "$last"
    s="$(secret_json)"
    for k in "${HK[@]}"; do
      want="$(jq -r --arg k "$k" '.keys[$k].to // empty' <<<"$last")"; have="$(value_of "$s" "$k")"
      [[ "$want" == "$have" || "$FORCE" == 1 ]] || { echo "REFUSED: $k is '$have', but the last change (#$(jq .seq <<<"$last") $(jq -r .id <<<"$last")) wrote '$want' — changed outside the ledger? (--force)" >&2; exit 2; }
    done
    change rollback "$ID" "$(jq -r .id <<<"$last")" "$(jq -c '.keys | with_entries(.value = .value.from)' <<<"$last")" \
      "$(jq -r '.port.from // empty' <<<"$last")" "$(jq -r .fromDb <<<"$last")" "$(jq -r .toDb <<<"$last")"
    ;;
  failback)
    [[ -n "$REF" && -n "$ID" ]] || { echo "usage: failback --to <change-id> --id ID" >&2; exit 2; }
    ref="$(entries | jq -c --arg r "$REF" '[.[] | select(.id == $r)] | first // empty')"
    [[ -n "$ref" ]] || { echo "ERROR: no change '$REF' in $LEDGER — see: $0 ... history" >&2; exit 2; }
    same_keys "$ref"
    change failback "$ID" "$REF" "$(jq -c '.keys | with_entries(.value = .value.from)' <<<"$ref")" \
      "$(jq -r '.port.from // empty' <<<"$ref")" "$(jq -r .fromDb <<<"$ref")" ""
    ;;
  *) sed -n '2,24p' "$0"; exit 2 ;;
esac
