#!/usr/bin/env bash
# dr-eks-rollout.sh — Kubernetes side of the secret cutover (CP-01) and S1 restarts.
#   inventory [secret]             : every Deployment/StatefulSet/DaemonSet/CronJob consuming the Secret, Reloader-annotated or not
#   snapshot-generations [secret]  : record metadata.generation of consumers (called right before the secret update)
#   wait [secret]                  : annotated consumers: wait until Reloader restarted them (generation bump), else manual restart
#                                    (reported as RELOADER FAILED). Unannotated consumers: Reloader never touches them;
#                                    RESTART_UNANNOTATED=true (default) restarts them manually, false leaves + reports them.
#                                    Ordered by dr.example.com/restart-order (1 poolers → 2 APIs → 3 workers).
#   restart [secret]               : manual ordered `rollout restart` of all consumers (Reloader down, or S1 stale pools)
#   check [secret]                 : which consumers still run with the OLD secret (STALE) — exit 1 if any
#   restart-stale [secret]         : restart only the STALE consumers (e.g. app-c left by RESTART_UNANNOTATED=false)
#   (check/restart-stale use the standalone tool k8s-secret-consumers.sh, which can also be run by hand)
#   suspend-cronjobs | resume-cronjobs [secret]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=dr-lib.sh
source "$HERE/dr-lib.sh"
dr_guard || exit 1
: "${EKS_CONTEXT:?}" "${K8S_NS:?}"
CMD="${1:-}"; SECRET="${2:-${K8S_SECRET:?}}"
K="kubectl --context ${EKS_CONTEXT} -n ${K8S_NS}"
OUT="${DR_EVIDENCE_DIR:-$(pwd)/evidence/adhoc}/k8s"; mkdir -p "$OUT"
RELOADER_GRACE_S="${RELOADER_GRACE_S:-90}"
SC=("$HERE/k8s-secret-consumers.sh" --context "$EKS_CONTEXT" -n "$K8S_NS" -s "$SECRET")

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
  local gens="$OUT/generations-${SECRET}.tsv" report="$OUT/reload-report-${SECRET}.txt"
  [[ -f "$gens" ]] || { echo "no generation snapshot — run snapshot-generations before the secret update"; exit 1; }
  : > "$report"
  for order in $(consumers | cut -f2 | sort -nu); do
    echo "== restart-order ${order}"
    while IFS=$'\t' read -r obj _ rl; do
      local before now deadline
      before="$(awk -F'\t' -v o="$obj" '$1==o{print $2}' "$gens")"
      if [[ "$rl" == "NO" ]]; then
        # Not Reloader-managed: Reloader must NOT touch it; we decide explicitly.
        now="$($K get "$obj" -o jsonpath='{.metadata.generation}')"
        (( now > before )) && echo "$obj: UNEXPECTED — generation changed without Reloader annotation" | tee -a "$report"
        if [[ "${RESTART_UNANNOTATED:-true}" == "true" ]]; then
          echo "$obj: UNANNOTATED → manual rollout restart (RESTART_UNANNOTATED=true)" | tee -a "$report"
          $K rollout restart "$obj"
        else
          echo "$obj: UNANNOTATED → SKIPPED, still using the OLD endpoint until restarted (RESTART_UNANNOTATED=false)" | tee -a "$report"
          continue
        fi
      else
        deadline=$(( $(date +%s) + RELOADER_GRACE_S ))
        while :; do
          now="$($K get "$obj" -o jsonpath='{.metadata.generation}')"
          (( now > before )) && { echo "$obj: RELOADED by Reloader (generation $before→$now)" | tee -a "$report"; break; }
          if (( $(date +%s) > deadline )); then
            echo "$obj: RELOADER FAILED (no restart after ${RELOADER_GRACE_S}s) → manual rollout restart" | tee -a "$report"
            $K rollout restart "$obj"; break
          fi
          sleep 3
        done
      fi
      $K rollout status "$obj" --timeout=600s 2>&1 | tee "$OUT/rollout-status-${obj//\//_}.txt"
    done < <(consumers | awk -F'\t' -v o="$order" '$2==o && $1 !~ /^cronjob\//')
  done
  $K get pods -o wide > "$OUT/pods-wide.txt"
  $K get events --sort-by=.lastTimestamp > "$OUT/events.txt"
  echo "--- reload report: $report"; cat "$report"
  echo "--- stale check (pods still holding the old secret):"
  "${SC[@]}" check | tee "$OUT/stale-check-${SECRET}.txt" || echo "STALE consumers remain → '$0 restart-stale' when allowed (see report)"
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
  restart)               dr_confirm "rolling restart of all consumers of $SECRET" && restart_all ;;
  check)                 "${SC[@]}" check | tee "$OUT/stale-check-${SECRET}.txt"; exit "${PIPESTATUS[0]}" ;;
  restart-stale)         dr_confirm "restart STALE consumers of $SECRET" && "${SC[@]}" restart | tee "$OUT/restart-stale-${SECRET}.txt" ;;
  suspend-cronjobs)      cronjobs true ;;
  resume-cronjobs)       cronjobs false ;;
  *) echo "usage: $0 {inventory|snapshot-generations|wait|restart|check|restart-stale|suspend-cronjobs|resume-cronjobs} [k8s-secret]"; exit 2 ;;
esac
