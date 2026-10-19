#!/usr/bin/env bash
set -euo pipefail
set +x
STATE=/workspace/tests/local/.state
source "$STATE/local.env"
[[ "$DR_ENV" == local && "$AWS_PROFILE" == dr-local && "$ACCOUNT_ID" == 000000000000 && "$EKS_CONTEXT" == dr-local ]] \
  || { echo 'REFUSED: isolated local fixture required.' >&2; exit 2; }
export KUBECONFIG="$STATE/kubeconfig"
configuration="$(kubectl --context "$EKS_CONTEXT" config view --raw -o json)"
cluster_name="$(jq -r --arg context "$EKS_CONTEXT" '.contexts[] | select(.name==$context) | .context.cluster' <<<"$configuration")"
cluster="$(jq -c --arg name "$cluster_name" '.clusters[] | select(.name==$name)' <<<"$configuration")"
token="$(kubectl --context "$EKS_CONTEXT" -n app create token dr-operator --duration=4h)"
umask 077
jq -n --argjson cluster "$cluster" --arg token "$token" \
  '{apiVersion:"v1",kind:"Config",clusters:[$cluster],users:[{name:"dr-operator",user:{token:$token}}],
    contexts:[{name:"dr-local",context:{cluster:$cluster.name,user:"dr-operator",namespace:"app"}}],"current-context":""}' \
  > "$STATE/operator-kubeconfig"
chmod 600 "$STATE/operator-kubeconfig"
unset token configuration
export KUBECONFIG="$STATE/operator-kubeconfig"
[[ "$(kubectl --context "$EKS_CONTEXT" -n app auth can-i get secrets/app-db-endpoint)" == yes ]]
for resource in secrets/app-db-direct secrets/app-db-credentials; do
  permission="$(kubectl --context "$EKS_CONTEXT" -n app auth can-i get "$resource" || true)"
  [[ "$permission" == no ]] || { echo 'REFUSED: operator has credential access or authorization could not be checked.' >&2; exit 2; }
done
for operation in 'list secrets' 'create pods/exec' 'patch deployments' 'create pods'; do
  read -r verb resource <<<"$operation"
  permission="$(kubectl --context "$EKS_CONTEXT" -n app auth can-i "$verb" "$resource" || true)"
  [[ "$permission" == no ]] || { echo 'REFUSED: operator has unsafe workload/Secret permissions or authorization check failed.' >&2; exit 2; }
done
echo 'Local operator kubeconfig prepared (4-hour token); credential Secret reads, pod exec and workload mutation denied.'