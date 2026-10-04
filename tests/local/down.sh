#!/usr/bin/env bash
# down.sh — remove the local DR test bed.
# K3S_MODE=existing: refuses unless the API server is local AND kube-system/dr-cluster-identity says env=local.
# Docker resources touched are only the drtest-* containers/volume/network created by up.sh.
HERE="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$HERE/.state/kubeconfig" && "${K3S_MODE:-docker}" == "existing" ]]; then
  # SAFETY: only clean up a cluster that is local AND identifies as env=local (written by up.sh). Anything else → refuse.
  KCF=(--kubeconfig "$HERE/.state/kubeconfig" --context dr-local --request-timeout=10s)
  SERVER="$(kubectl --kubeconfig "$HERE/.state/kubeconfig" config view -o jsonpath='{.clusters[?(@.name=="dr-local")].cluster.server}')"
  IDENT="$(kubectl "${KCF[@]}" -n kube-system get configmap dr-cluster-identity -o jsonpath='{.data.env}' 2>/dev/null || true)"
  [[ "$SERVER" =~ ^https?://(\[?)(127\.[0-9.]+|localhost|::1|0\.0\.0\.0|kubernetes\.docker\.internal)(\]?)(:[0-9]+)?/?$ ]] \
    || { echo "REFUSED: API server '$SERVER' is not local — nothing removed." >&2; exit 2; }
  [[ "$IDENT" == local ]] \
    || { echo "REFUSED: cluster identity is env='${IDENT:-<none>}', expected 'local' (kube-system/dr-cluster-identity) — nothing removed." >&2; exit 2; }
  KC=(--kubeconfig "$HERE/.state/kubeconfig" --kube-context dr-local)
  helm "${KC[@]}" uninstall reloader -n reloader >/dev/null 2>&1; helm "${KC[@]}" uninstall external-secrets -n external-secrets >/dev/null 2>&1
  kubectl --kubeconfig "$HERE/.state/kubeconfig" --context dr-local delete ns app reloader external-secrets --wait=true --timeout=300s >/dev/null 2>&1
  kubectl --kubeconfig "$HERE/.state/kubeconfig" --context dr-local -n kube-system delete configmap dr-cluster-identity >/dev/null 2>&1
fi
docker rm -f drtest-k3s drtest-localstack drtest-pg-old drtest-pg-replica drtest-pg-restored >/dev/null 2>&1
docker volume rm drtest-k3s-data >/dev/null 2>&1
docker network rm drtest >/dev/null 2>&1
pkill -f "[m]oto_launcher.py|[m]oto_server" 2>/dev/null
rm -rf "$HERE/.state" "$HERE/evidence"
echo "DOWN."
