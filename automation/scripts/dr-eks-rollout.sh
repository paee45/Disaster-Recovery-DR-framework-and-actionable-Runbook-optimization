#!/usr/bin/env bash
# dr-eks-rollout.sh — Kubernetes side of the secret cutover (CP-01) and S1 restarts.
#   inventory [secret]             : every Deployment/StatefulSet/DaemonSet/CronJob consuming the Secret, Reloader-annotated or not
#   snapshot-generations [secret]  : record metadata.generation of consumers (called right before the secret update)
#   wait [secret]                  : wait until Reloader bumped each annotated consumer (generation increased), then rollout status,
#                                    in dr.example.com/restart-order (1 poolers → 2 APIs → 3 workers). Falls back to manual restart.
#   restart [secret]               : manual ordered `rollout restart` of all consumers (Reloader down, or S1 stale pools)
#   suspend-cronjobs | resume-cronjobs [secret]
set -euo pipefail
: "${EKS_CONTEXT:?}" "${K8S_NS:?}"
CMD="${1:-}"; SECRET="${2:-${K8S_SECRET:?}}"
K="kubectl --context ${EKS_CONTEXT} -n ${K8S_NS}"
OUT="${DR_EVIDENCE_DIR:-$(pwd)/evidence/adhoc}/k8s"; mkdir -p "$OUT"
RELOADER_GRACE_S="${RELOADER_GRACE_S:-90}"

# kind/name <TAB> restart-order <TAB> reloader(YES|NO) for consumers of $SECRET
consumers() {
  $K get deploy,statefulset,daemonset,cronjob -o json | jq -r --arg s "$SECRET" '
    .items[]
    | select([.. | objects | (.secretRef.name?, .secretKeyRef.name?, .secret.secretName?)] | any(. == $s))
    | (.metadata.annotations // {}) as $a
    | [ (.kind | ascii_downcase) + "/" + .metadata.name,
        (.metadata.labels["dr.example.com/restart-order"] // "2"),
        (if (($a["secret.reloader.stakater.com/reload"] // "") | split(",") | index($s)) or $a["reloader.stakater.com/auto"] == "true"
           or $a["secret.reloader.stakater.com/auto"] == "true" then "YES" else "NO" end) ] | @tsv' | sort -t$'\t' -k2,2n
}

inventory() {
  consumers | while IFS=$'\t' read -r obj order rl; do printf '%-50s order=%s reloader=%s\n' "$obj" "$order" "$rl"; done \
    | tee "$OUT/inventory-${SECRET}.txt"
}

snapshot_generations() {
  consumers | grep -v '^cronjob/' | while IFS=$'\t' read -r obj _ _; do
    printf '%s\t%s\n' "$obj" "$($K get "$obj" -o jsonpath='{.metadata.generation}')"
  done > "$OUT/generations-${SECRET}.tsv"
}

wait_rollouts() {
  local gens="$OUT/generations-${SECRET}.tsv"
  [[ -f "$gens" ]] || { echo "no generation snapshot — run snapshot-generations before the secret update"; exit 1; }
  for order in $(consumers | cut -f2 | sort -nu); do
    echo "== restart-order ${order}"
    consumers | awk -F'\t' -v o="$order" '$2==o && $1 !~ /^cronjob\//' | while IFS=$'\t' read -r obj _ rl; do
      local before now deadline
      before="$(awk -F'\t' -v o="$obj" '$1==o{print $2}' "$gens")"
      deadline=$(( $(date +%s) + RELOADER_GRACE_S ))
      while :; do
        now="$($K get "$obj" -o jsonpath='{.metadata.generation}')"
        (( now > before )) && { echo "$obj: reloaded (generation $before→$now)"; break; }
        if (( $(date +%s) > deadline )); then
          echo "$obj: NOT reloaded after ${RELOADER_GRACE_S}s (reloader=$rl) → manual rollout restart"
          $K rollout restart "$obj"; break
        fi
        sleep 3
      done
      $K rollout status "$obj" --timeout=600s 2>&1 | tee "$OUT/rollout-status-${obj//\//_}.txt"
    done
  done
  $K get pods -o wide > "$OUT/pods-wide.txt"
  $K get events --sort-by=.lastTimestamp > "$OUT/events.txt"
}

restart_all() {
  for order in $(consumers | cut -f2 | sort -nu); do
    echo "== restart-order ${order}"
    mapfile -t objs < <(consumers | awk -F'\t' -v o="$order" '$2==o && $1 !~ /^cronjob\//{print $1}')
    (( ${#objs[@]} == 0 )) && continue
    for o in "${objs[@]}"; do $K rollout restart "$o"; done
    for o in "${objs[@]}"; do $K rollout status "$o" --timeout=600s 2>&1 | tee "$OUT/rollout-status-${o//\//_}.txt"; done
  done
}

cronjobs() {
  local val="$1"
  consumers | awk -F'\t' '$1 ~ /^cronjob\//{print $1}' | while read -r cj; do
    $K patch "$cj" --type merge -p "{\"spec\":{\"suspend\":${val}}}" && echo "$cj suspend=${val}"
  done | tee -a "$OUT/cronjobs-${SECRET}.txt"
}

case "$CMD" in
  inventory)             inventory ;;
  snapshot-generations)  snapshot_generations ;;
  wait)                  wait_rollouts ;;
  restart)               restart_all ;;
  suspend-cronjobs)      cronjobs true ;;
  resume-cronjobs)       cronjobs false ;;
  *) echo "usage: $0 {inventory|snapshot-generations|wait|restart|suspend-cronjobs|resume-cronjobs} [k8s-secret]"; exit 2 ;;
esac
