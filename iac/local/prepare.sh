#!/usr/bin/env bash
set -euo pipefail
STATE=/workspace/tests/local/.state
[[ -f "$STATE/kubeconfig" ]] || { echo 'Missing local kubeconfig.' >&2; exit 2; }
export KUBECONFIG="$STATE/kubeconfig"
python3 - "$STATE/kubeconfig" <<'PY'
import sys
import yaml
with open(sys.argv[1]) as source:
    config = yaml.safe_load(source)
cluster = config['clusters'][0]
user = config['users'][0]
cluster['name'] = user['name'] = 'dr-local'
if cluster['cluster']['server'] not in ('https://127.0.0.1:6443', 'https://localhost:6443'):
    raise SystemExit('REFUSED: kubeconfig is not the local k3s API')
cluster['cluster']['server'] = 'https://localhost:6443'
result = {'apiVersion': 'v1', 'kind': 'Config', 'clusters': [cluster], 'users': [user],
          'contexts': [{'name': 'dr-local', 'context': {'cluster': 'dr-local', 'user': 'dr-local'}},
                       {'name': 'decoy', 'context': {'cluster': 'decoy', 'user': 'dr-local'}}]}
result['clusters'].append({'name': 'decoy', 'cluster': {'server': 'https://198.51.100.7:6443',
                                                     'insecure-skip-tls-verify': True}})
with open(sys.argv[1], 'w') as target:
    yaml.safe_dump(result, target)
PY
chmod 600 "$STATE/kubeconfig"
cp "$STATE/kubeconfig" /tmp/dr-local-kubeconfig
chmod 600 /tmp/dr-local-kubeconfig
export KUBECONFIG=/tmp/dr-local-kubeconfig
ready=0
for ((attempt=1; attempt<=60; attempt++)); do
    if kubectl --context dr-local --request-timeout=5s get --raw=/readyz >/dev/null 2>&1; then ready=1; break; fi
    if ((attempt < 60)); then sleep 2; fi
done
[[ "$ready" == 1 ]] || { echo 'Local k3s API did not become ready.' >&2; exit 1; }
kubectl --context dr-local --request-timeout=10s wait --for=condition=Ready nodes --all --timeout=180s
for endpoint in http://127.0.0.1:5000/moto-api/ http://172.30.0.10:4566/_localstack/health; do
    curl --fail --silent --show-error --retry 30 --retry-connrefused --retry-delay 2 \
        --connect-timeout 3 --max-time 5 --retry-max-time 180 "$endpoint" >/dev/null
done
for host in 172.30.0.21 172.30.0.22 172.30.0.23; do
    expected='100|50|1'
    [[ "$host" != 172.30.0.23 ]] || expected='80|40|1'
    ready=0
    for ((attempt=1; attempt<=60; attempt++)); do
        if pg_isready -h "$host" -p 5432 -U postgres -d app -t 3 >/dev/null 2>&1 \
            && rows="$(PGPASSWORD=masterpw PGOPTIONS='-c statement_timeout=5000' \
                psql "host=$host port=5432 dbname=app user=postgres sslmode=disable connect_timeout=3" \
                    -XAtq -v ON_ERROR_STOP=1 -c 'SELECT (SELECT count(*) FROM public.orders),
                        (SELECT count(*) FROM public.payments), (SELECT count(*) FROM dr.heartbeat)' 2>/dev/null)" \
            && [[ "$rows" == "$expected" ]]; then ready=1; break; fi
        if ((attempt < 60)); then sleep 2; fi
    done
    [[ "$ready" == 1 ]] || { echo "Seeded Postgres at $host did not become ready (expected $expected)." >&2; exit 1; }
    printf '%s: %s\n' "$host" "$rows"
done
echo 'Local API, mock endpoints, and seeded Postgres are reachable.'