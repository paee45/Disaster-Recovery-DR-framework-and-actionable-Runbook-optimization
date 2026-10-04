#!/usr/bin/env bash
# k8s-secret-consumers.sh — standalone tool: which workloads use a Secret, which are STALE after the Secret changed,
# and restart ONLY the stale ones. Usable manually, from the runbooks, or from dr-eks-rollout.sh.
#
#   k8s-secret-consumers.sh [opts] list                         all consumers (Deployment/StatefulSet/DaemonSet/CronJob)
#   k8s-secret-consumers.sh [opts] check                        UP-TO-DATE / STALE per workload; exit 1 if any STALE
#   k8s-secret-consumers.sh [opts] restart [--all] [--dry-run]  restart STALE workloads only (or --all), in restart-order
#   k8s-secret-consumers.sh [opts] restart-one <kind/name>      restart one workload and stamp the secret fingerprint
#
# Options (or env):  --context CTX (EKS_CONTEXT)   -n|--namespace NS (K8S_NS)   -s|--secret NAME (K8S_SECRET)
#                    --only-unannotated | --only-annotated    filter by Reloader annotation
#                    --expect-env ENV  refuse unless kube-system/dr-cluster-identity says env=ENV (DR_ENV)
# There is NO fallback to the current kube context: a context is mandatory (avoids acting on the wrong cluster).
#
# How "changed" is decided (no exec into pods needed):
#   fingerprint  = sha256 of the Secret's .data (sorted)          → "what the pods SHOULD have"
#   changed_at   = last time a manager wrote .data of the Secret   (managedFields; ESO only writes on data change)
#   A workload is UP-TO-DATE if this tool restarted it for the current fingerprint (template annotation
#   dr.example.com/secret-fp.<secret>), or if ALL its running pods started after changed_at (covers Reloader and manual
#   restarts). Otherwise STALE. A false STALE only costs an extra restart; a missed one would leave pods on the old DB.
#   Note: ESO rewrites the Secret only when the data changes, so changed_at is not moved by routine refreshes.
set -euo pipefail
# macOS: the scripts need bash >= 4 and GNU date/sha256sum (brew install bash coreutils jq libpq awscli kubectl).
if [[ "$(uname -s)" == Darwin ]]; then
  for _d in /opt/homebrew/opt/coreutils/libexec/gnubin /usr/local/opt/coreutils/libexec/gnubin /opt/homebrew/opt/libpq/bin /usr/local/opt/libpq/bin; do
    [[ -d "$_d" && ":$PATH:" != *":$_d:"* ]] && PATH="$_d:$PATH"
  done; export PATH
fi
if (( BASH_VERSINFO[0] < 4 )) || ! date -u -d '2020-01-01T00:00:00Z' +%s >/dev/null 2>&1 || ! command -v sha256sum >/dev/null; then
  echo "ERROR: need bash>=4 + GNU coreutils (macOS: brew install bash coreutils; run with the brew bash)" >&2; return 1 2>/dev/null || exit 1
fi

CTX="${EKS_CONTEXT:-}"; NS="${K8S_NS:-}"; SECRET="${K8S_SECRET:-}"; FILTER=all; EXPECT_ENV="${DR_ENV:-}"; DRY=0; ALL=0
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) CTX="$2"; shift 2 ;;
    -n|--namespace) NS="$2"; shift 2 ;;
    -s|--secret) SECRET="$2"; shift 2 ;;
    --only-unannotated) FILTER=no; shift ;;
    --only-annotated) FILTER=yes; shift ;;
    --expect-env) EXPECT_ENV="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --all) ALL=1; shift ;;
    -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
set -- "${ARGS[@]}"
CMD="${1:-}"
[[ -n "$CTX" ]] || { echo "ERROR: --context (or EKS_CONTEXT) is mandatory — the current context is never used" >&2; exit 2; }
[[ -n "$NS" && -n "$SECRET" ]] || { echo "ERROR: --namespace and --secret are mandatory" >&2; exit 2; }
K=(kubectl --context "$CTX" --request-timeout=20s -n "$NS")
ANN="dr.example.com/secret-fp.${SECRET}"

if [[ -n "$EXPECT_ENV" && "${REQUIRE_CLUSTER_IDENTITY:-true}" == "true" ]]; then
  got="$(kubectl --context "$CTX" --request-timeout=10s -n kube-system get configmap dr-cluster-identity -o jsonpath='{.data.env}' 2>/dev/null || true)"
  [[ "$got" == "$EXPECT_ENV" ]] || { echo "REFUSED: context '$CTX' identifies as env='${got:-?}', expected '$EXPECT_ENV'" >&2; exit 2; }
fi

secret_json() { "${K[@]}" get secret "$SECRET" -o json --show-managed-fields; }   # kubectl ≥1.21 hides managedFields by default
fingerprint() { jq -cS '.data // {}' | sha256sum | cut -c1-16; }
# no silent fallback: without a managedFields entry for .data we cannot tell old pods from new ones → stop
changed_at() { jq -r '[.metadata.managedFields[]? | select((.fieldsV1 // {}) | tostring | contains("\"f:data\"")) | .time] | max // empty'; }
to_epoch() { date -u -d "$1" +%s; }

# kind/name <TAB> restart-order <TAB> reloader(YES|NO) <TAB> stamped-fingerprint <TAB> selector-json
consumers() {
  "${K[@]}" get deploy,statefulset,daemonset,cronjob -o json | jq -r --arg s "$SECRET" --arg ann "$ANN" --arg f "$FILTER" '
    .items[]
    | select([.. | objects | (.secretRef.name?, .secretKeyRef.name?, .secret.secretName?)] | any(. == $s))
    | (.metadata.annotations // {}) as $a
    | (if (($a["secret.reloader.stakater.com/reload"] // "") | split(",") | map(gsub("^ +| +$";"")) | index($s))
          or $a["reloader.stakater.com/auto"] == "true" or $a["secret.reloader.stakater.com/auto"] == "true"
       then "YES" else "NO" end) as $rl
    | select($f == "all" or ($f == "yes" and $rl == "YES") or ($f == "no" and $rl == "NO"))
    | ((.spec.template.metadata.annotations // .spec.jobTemplate.spec.template.metadata.annotations // {})[$ann] // "-") as $fp
    | [ (.kind | ascii_downcase) + "/" + .metadata.name,
        (.metadata.labels["dr.example.com/restart-order"] // "2"), $rl, $fp,
        ((.spec.selector.matchLabels // {}) | tojson) ] | @tsv' | sort -t$'\t' -k2,2n
}

# prints: STATE <TAB> detail      (STATE = UP-TO-DATE | STALE | N/A)
state_of() { # kind/name rl stamped selector current_fp changed_epoch
  local obj="$1" stamped="$3" sel="$4" fp="$5" chg="$6" oldest sel_q
  [[ "$obj" == cronjob/* ]] && { printf 'N/A\tnext run reads the current Secret\n'; return; }
  # fast path: restarted by this tool for exactly this secret content. A different stamp is NOT proof of staleness
  # (Reloader / kubectl rollout restart may have restarted it since) → fall through to the pod start-time check.
  [[ "$stamped" == "$fp" ]] && { printf 'UP-TO-DATE\tstamped fingerprint matches\n'; return; }
  sel_q="$(jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")' <<<"$sel")"
  oldest="$("${K[@]}" get pods -l "$sel_q" --field-selector=status.phase=Running -o json \
            | jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | .status.startTime] | min // empty')"
  [[ -z "$oldest" ]] && { printf 'STALE\tno running pods\n'; return; }
  if (( $(to_epoch "$oldest") < chg )); then printf 'STALE\toldest pod started %s < secret changed %s\n' "$oldest" "$(date -u -d "@$chg" +%FT%TZ)"
  else printf 'UP-TO-DATE\tall pods started after the secret changed (%s)\n' "$oldest"; fi
}

restart_one() { # kind/name fingerprint
  local obj="$1" fp="$2" path='{"spec":{"template":{"metadata":{"annotations":{"%s":"%s","dr.example.com/restarted-at":"%s"}}}}}'
  if (( DRY )); then echo "DRY-RUN restart $obj (stamp $fp)"; return 0; fi
  # shellcheck disable=SC2059
  "${K[@]}" patch "$obj" --type merge -p "$(printf "$path" "$ANN" "$fp" "$(date -u +%FT%TZ)")" >/dev/null
  echo "restarting $obj (stamp $fp)"
}

S="$(secret_json)"; FP="$(fingerprint <<<"$S")"; CHG_TS="$(changed_at <<<"$S")"
[[ -n "$CHG_TS" ]] || { echo "ERROR: cannot determine when $NS/$SECRET data last changed (no managedFields for .data) — refusing to guess; use 'restart --all' if needed" >&2; exit 3; }
CHG="$(to_epoch "$CHG_TS")"

case "$CMD" in
  list)
    printf '%-40s %-6s %-9s %s\n' WORKLOAD ORDER RELOADER STAMPED_FP
    consumers | while IFS=$'\t' read -r obj order rl st _; do printf '%-40s %-6s %-9s %s\n' "$obj" "$order" "$rl" "$st"; done ;;
  check)
    echo "secret $NS/$SECRET  fingerprint=$FP  data-changed-at=$CHG_TS  context=$CTX"
    stale=0
    while IFS=$'\t' read -r obj order rl st sel; do
      IFS=$'\t' read -r state detail <<<"$(state_of "$obj" "$rl" "$st" "$sel" "$FP" "$CHG")"
      printf '%-11s %-40s reloader=%-3s order=%s  %s\n' "$state" "$obj" "$rl" "$order" "$detail"
      [[ "$state" == STALE ]] && stale=$((stale+1))
    done < <(consumers)
    echo "stale=$stale"; (( stale == 0 )) ;;
  restart)
    n=0
    for order in $(consumers | cut -f2 | sort -nu); do
      batch=()
      while IFS=$'\t' read -r obj _ rl st sel; do
        [[ "$obj" == cronjob/* ]] && continue
        if (( ALL )); then batch+=("$obj"); continue; fi
        state="$(state_of "$obj" "$rl" "$st" "$sel" "$FP" "$CHG" | cut -f1)"
        [[ "$state" == STALE ]] && batch+=("$obj") || echo "skip $obj ($state)"
      done < <(consumers | awk -F'\t' -v o="$order" '$2==o')
      (( ${#batch[@]} )) || continue
      for o in "${batch[@]}"; do restart_one "$o" "$FP"; n=$((n+1)); done
      (( DRY )) || for o in "${batch[@]}"; do "${K[@]}" rollout status "$o" --timeout=600s; done
    done
    echo "restarted=$n" ;;
  restart-one)
    restart_one "${2:?kind/name}" "$FP"
    (( DRY )) || "${K[@]}" rollout status "$2" --timeout=600s ;;
  *) sed -n '2,23p' "$0"; exit 2 ;;
esac
