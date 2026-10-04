#!/usr/bin/env bash
# dr-eks-rollout.sh — Phase 3 compute recovery in the DR EKS cluster.
#   scale   : scale DR-labelled deployments to production capacity (annotation dr.example.com/prod-replicas)
#   restart : ordered rolling restart by tier label dr.example.com/restart-order (1=pools/proxies, 2=APIs, 3=workers)
# Every kubectl output is written to the evidence dir.
set -euo pipefail
: "${EKS_DR:?}" "${K8S_NS:?}" "${DR_EVIDENCE_DIR:?source dr-lib.sh and run dr_init}"
SELECTOR="${DR_SELECTOR:-dr.example.com/tier=critical}"
K="kubectl --context ${EKS_DR} -n ${K8S_NS}"
OUT="${DR_EVIDENCE_DIR}/k8s"; mkdir -p "$OUT"

scale() {
  $K get deploy -l "$SELECTOR" -o json \
  | jq -r '.items[] | [.metadata.name, (.metadata.annotations["dr.example.com/prod-replicas"] // "")] | @tsv' \
  | while IFS=$'\t' read -r name replicas; do
      if [[ -z "$replicas" ]]; then echo "SKIP $name (no prod-replicas annotation)"; continue; fi
      # If an HPA owns the deployment, raise its floor instead of fighting it.
      if $K get hpa "$name" >/dev/null 2>&1; then
        $K patch hpa "$name" --type merge -p "{\"spec\":{\"minReplicas\":${replicas}}}"
      else
        $K scale deploy "$name" --replicas="$replicas"
      fi
    done | tee "$OUT/scale.txt"
}

restart() {
  for order in 1 2 3; do
    mapfile -t deps < <($K get deploy -l "${SELECTOR},dr.example.com/restart-order=${order}" -o name)
    (( ${#deps[@]} == 0 )) && continue
    echo "== restart order ${order}: ${deps[*]}"
    for d in "${deps[@]}"; do $K rollout restart "$d"; done
    for d in "${deps[@]}"; do
      $K rollout status "$d" --timeout=300s 2>&1 | tee "$OUT/rollout-status-${d#deployment.apps/}.txt"
    done
  done
  $K get pods -o wide > "$OUT/pods-wide.txt"
  $K get events --sort-by=.lastTimestamp > "$OUT/events.txt"
  $K get externalsecret -o yaml > "$OUT/externalsecret-status.yaml" || true
}

case "${1:-}" in
  scale)   scale ;;
  restart) restart ;;
  *) echo "usage: $0 {scale|restart}"; exit 2 ;;
esac
