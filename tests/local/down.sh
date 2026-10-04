#!/usr/bin/env bash
# down.sh — remove the local DR test bed
HERE="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$HERE/.state/kubeconfig" && "${K3S_MODE:-docker}" == "existing" ]]; then
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
