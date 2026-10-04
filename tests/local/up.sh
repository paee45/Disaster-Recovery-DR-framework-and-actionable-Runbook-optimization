#!/usr/bin/env bash
# up.sh — local DR test bed: k3s (in Docker) + LocalStack + moto (RDS/EC2 mock) + 3 Postgres "RDS instances"
#         + External Secrets Operator + Stakater Reloader + 3 sample apps (2 Reloader-annotated, 1 not) + 1 CronJob.
# Usage: tests/local/up.sh                                   (k3s in Docker)
#        K3S_MODE=existing EXISTING_KUBECONFIG=~/.kube/k3d.yaml tests/local/up.sh   (bring your own k3s/k3d/kind)
# Run down.sh for a clean slate. Nothing outside tests/local/.state and the drtest-* containers is touched.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
LOCAL_API_RE='^https?://(\[?)(127\.[0-9.]+|localhost|::1|0\.0\.0\.0|kubernetes\.docker\.internal)(\]?)(:[0-9]+)?/?$'
if [[ "${K3S_MODE:-docker}" == existing ]]; then   # refuse a non-local cluster BEFORE anything is created
  _srv="$(kubectl --kubeconfig "${EXISTING_KUBECONFIG:?set EXISTING_KUBECONFIG for K3S_MODE=existing}" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null \
          || kubectl --kubeconfig "$EXISTING_KUBECONFIG" config view -o jsonpath='{.clusters[0].cluster.server}')"
  [[ "$_srv" =~ $LOCAL_API_RE ]] || { echo "REFUSED: EXISTING_KUBECONFIG points at '$_srv' — up.sh only runs against a local cluster (127.x/localhost/::1)." >&2; exit 2; }
fi
STATE="$HERE/.state"; mkdir -p "$STATE"
NET=drtest; SUBNET=172.30.0.0/24
IP_LS=172.30.0.10; IP_OLD=172.30.0.21; IP_REPLICA=172.30.0.22; IP_RESTORED=172.30.0.23
K3S_IMAGE="${K3S_IMAGE:-rancher/k3s:v1.31.4-k3s1}"; LS_IMAGE="${LS_IMAGE:-localstack/localstack:4.0}"; PG_IMAGE=postgres:16-alpine
MOTO_PORT=5000
log() { printf '\n== %s\n' "$*"; }

log "docker network $NET"
# nat-unprotected: Docker ≥ 28 otherwise drops traffic from k3s pods to container IPs ("direct routing protection")
docker network inspect "$NET" >/dev/null 2>&1 || docker network create --subnet "$SUBNET" \
  -o com.docker.network.bridge.gateway_mode_ipv4=nat-unprotected "$NET" >/dev/null 2>&1 \
  || docker network create --subnet "$SUBNET" "$NET" >/dev/null

log "postgres containers (old primary / replica / restored)"
pg() { # name ip orders payments app_pw heartbeat_age_min
  docker rm -f "$1" >/dev/null 2>&1 || true
  docker run -d --name "$1" --network "$NET" --ip "$2" -e POSTGRES_PASSWORD=masterpw "$PG_IMAGE" >/dev/null
  until docker exec "$1" pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done; sleep 2
  docker exec -i "$1" psql -U postgres -v ON_ERROR_STOP=1 -v orders="$3" -v payments="$4" -v app_pw="$5" -v hb_age="$6" -q < "$HERE/seed.sql"
}
pg drtest-pg-old      "$IP_OLD"      100 50 apppw-current 0
pg drtest-pg-replica  "$IP_REPLICA"  100 50 apppw-current 0
pg drtest-pg-restored "$IP_RESTORED"  80 40 apppw-OLD     1020   # older restore point + OLD password (tests the password trap)

log "LocalStack ($LS_IMAGE) at $IP_LS"
docker rm -f drtest-localstack >/dev/null 2>&1 || true
docker run -d --name drtest-localstack --network "$NET" --ip "$IP_LS" -e SERVICES=secretsmanager,sts,s3,ssm,cloudwatch,logs,iam,kms \
  -e EAGER_SERVICE_LOADING=1 "$LS_IMAGE" >/dev/null
until curl -sf "http://$IP_LS:4566/_localstack/health" | grep -q '"secretsmanager": "\(available\|running\)"'; do sleep 2; done

log "moto (RDS/EC2 mock) on 127.0.0.1:$MOTO_PORT"
pkill -f "[m]oto_launcher.py|[m]oto_server" 2>/dev/null || true; sleep 1
MOTO_PY="${MOTO_PY:-/opt/drtest-venv/bin/python}"
nohup "$MOTO_PY" "$HERE/moto_launcher.py" -H 127.0.0.1 -p "$MOTO_PORT" > "$STATE/moto.log" 2>&1 &
until curl -sf "http://127.0.0.1:$MOTO_PORT/moto-api/" >/dev/null; do sleep 1; done

log "AWS profiles (isolated config in $STATE): dr-local (LocalStack + moto) and dr-decoy (another account)"
cat > "$STATE/aws-config" <<CFG
[profile dr-local]
region = eu-west-1
output = json
endpoint_url = http://$IP_LS:4566
services = dr-local-services

[services dr-local-services]
rds =
  endpoint_url = http://127.0.0.1:$MOTO_PORT
ec2 =
  endpoint_url = http://127.0.0.1:$MOTO_PORT

[profile dr-decoy]
region = eu-west-1
endpoint_url = http://127.0.0.1:$MOTO_PORT
CFG
cat > "$STATE/aws-credentials" <<CFG
[dr-local]
aws_access_key_id = test
aws_secret_access_key = test
[dr-decoy]
aws_access_key_id = decoy
aws_secret_access_key = decoy
CFG
export AWS_CONFIG_FILE="$STATE/aws-config" AWS_SHARED_CREDENTIALS_FILE="$STATE/aws-credentials"
A() { command aws --profile dr-local "$@"; }

log "mock AWS resources: VPC, 3 SGs, subnet/parameter groups, primary + replica, secrets, evidence bucket"
VPC=$(A ec2 create-vpc --cidr-block 10.0.0.0/16 --query Vpc.VpcId --output text)
SN1=$(A ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.0.1.0/24 --availability-zone eu-west-1a --query Subnet.SubnetId --output text)
SN2=$(A ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.0.2.0/24 --availability-zone eu-west-1b --query Subnet.SubnetId --output text)
SGS=""; for n in app db-access monitoring; do SGS+="$(A ec2 create-security-group --group-name "$n" --description "$n" --vpc-id "$VPC" --query GroupId --output text) "; done
QSG=$(A ec2 create-security-group --group-name quarantine --description "no inbound" --vpc-id "$VPC" --query GroupId --output text)
A rds create-db-subnet-group --db-subnet-group-name app-local-db-subnets --db-subnet-group-description local --subnet-ids "$SN1" "$SN2" >/dev/null
A rds create-db-parameter-group --db-parameter-group-name app-pg16-local --db-parameter-group-family postgres16 --description local >/dev/null
# shellcheck disable=SC2086
A rds create-db-instance --db-instance-identifier app-pg-local --engine postgres --db-instance-class db.t4g.micro --allocated-storage 20 \
  --master-username postgres --master-user-password masterpw --db-subnet-group-name app-local-db-subnets --vpc-security-group-ids $SGS \
  --db-parameter-group-name app-pg16-local --backup-retention-period 7 --deletion-protection \
  --copy-tags-to-snapshot --preferred-maintenance-window sun:03:00-sun:03:30 --preferred-backup-window 01:00-01:30 \
  --enable-cloudwatch-logs-exports postgresql upgrade \
  --tags '[{"Key":"app","Value":"orders"},{"Key":"owner","Value":"sre-team"},{"Key":"cost-center","Value":"CC 1234 / retail"},{"Key":"backup-plan","Value":"local-daily"}]' >/dev/null
A rds create-db-instance-read-replica --db-instance-identifier app-pg-local-replica --source-db-instance-identifier app-pg-local >/dev/null
A secretsmanager create-secret --name local/app/db --secret-string \
  "{\"engine\":\"postgres\",\"host\":\"$IP_OLD\",\"port\":5432,\"dbname\":\"app\",\"username\":\"app_user\",\"password\":\"apppw-current\",\"dbInstanceIdentifier\":\"app-pg-local\"}" >/dev/null
A secretsmanager create-secret --name local/app/db-master --secret-string '{"username":"postgres","password":"masterpw"}' >/dev/null
A s3api create-bucket --bucket org-dr-evidence-000000000000 --create-bucket-configuration LocationConstraint=eu-west-1 >/dev/null

log "endpoint map (LOCAL TEST SEAM: mock RDS ids → real Postgres containers)"
cat > "$STATE/endpoint-map" <<MAP
# pattern                host           port
app-pg-local             $IP_OLD       5432
app-pg-local-replica     $IP_REPLICA   5432
app-pg-local-r*          $IP_RESTORED  5432
app-pg-local-p*          $IP_RESTORED  5432
app-pg-local-drtest-*    $IP_RESTORED  5432
MAP

K3S_MODE="${K3S_MODE:-docker}"     # docker = k3s in a container (default) · existing = use EXISTING_KUBECONFIG (k3s/k3d/kind/Rancher Desktop)
if [[ "$K3S_MODE" == "docker" ]]; then
  log "k3s ($K3S_IMAGE) in Docker — host network so containerd can pull through a proxy if one is configured"
  docker rm -f drtest-k3s >/dev/null 2>&1 || true
  docker run -d --name drtest-k3s --privileged --network host \
    -e HTTPS_PROXY="${HTTPS_PROXY:-}" -e HTTP_PROXY="${HTTP_PROXY:-}" \
    -e NO_PROXY="localhost,127.0.0.1,10.42.0.0/16,10.43.0.0/16,172.30.0.0/24,.svc,.cluster.local" \
    ${K3S_CA_FILE:+-e SSL_CERT_FILE=/extra-ca.crt -v "$K3S_CA_FILE":/extra-ca.crt:ro} \
    -v drtest-k3s-data:/var/lib/rancher/k3s \
    "$K3S_IMAGE" server --disable traefik,metrics-server --write-kubeconfig-mode 600 >/dev/null
  until docker exec drtest-k3s kubectl get nodes 2>/dev/null | grep -q " Ready"; do sleep 2; done
  docker exec drtest-k3s cat /etc/rancher/k3s/k3s.yaml > "$STATE/kubeconfig.src"
  docker save --platform linux/amd64 "$PG_IMAGE" | docker exec -i drtest-k3s ctr -n k8s.io images import - >/dev/null 2>&1 \
    || echo "image import failed — k3s will pull $PG_IMAGE itself"
else
  log "existing cluster from EXISTING_KUBECONFIG=${EXISTING_KUBECONFIG:?set EXISTING_KUBECONFIG for K3S_MODE=existing}"
  cp "$EXISTING_KUBECONFIG" "$STATE/kubeconfig.src"
fi
# Normalise to ONE context named dr-local in a dedicated kubeconfig (never touch ~/.kube/config)
python3 - "$STATE/kubeconfig.src" "$STATE/kubeconfig" <<'PY'
import sys, yaml
c = yaml.safe_load(open(sys.argv[1]))
ctx = next(x for x in c["contexts"] if x["name"] == c.get("current-context", c["contexts"][0]["name"]))
cl = next(x for x in c["clusters"] if x["name"] == ctx["context"]["cluster"])
us = next(x for x in c["users"] if x["name"] == ctx["context"]["user"])
cl["name"] = us["name"] = ctx["name"] = "dr-local"; ctx["context"].update(cluster="dr-local", user="dr-local")
out = {"apiVersion": "v1", "kind": "Config", "clusters": [cl], "users": [us], "contexts": [ctx], "current-context": "dr-local"}
open(sys.argv[2], "w").write(yaml.safe_dump(out))
PY
chmod 600 "$STATE/kubeconfig"; rm -f "$STATE/kubeconfig.src"
export KUBECONFIG="$STATE/kubeconfig"
# SAFETY: the test bed installs Helm releases, namespaces and an identity ConfigMap — only ever on a LOCAL cluster.
SERVER="$(kubectl config view -o jsonpath='{.clusters[?(@.name=="dr-local")].cluster.server}')"
[[ "$SERVER" =~ $LOCAL_API_RE ]] \
  || { echo "REFUSED: API server '$SERVER' is not local (127.x/localhost/::1). up.sh only runs against a local test cluster." >&2; exit 2; }
# decoy context (another cluster) kept in the file; NO current-context (best practice — dr_guard refuses one).
# Tests A06/A15 set it temporarily to prove the scripts never use it.
kubectl config set-cluster decoy --server=https://198.51.100.7:6443 --insecure-skip-tls-verify=true   # TEST-NET-2: unroutable >/dev/null
kubectl config set-context decoy --cluster=decoy --user=dr-local >/dev/null
kubectl config unset current-context >/dev/null
K() { command kubectl --context dr-local "$@"; }
until K get nodes 2>/dev/null | grep -q " Ready"; do sleep 2; done
IDENT="$(K -n kube-system get configmap dr-cluster-identity -o jsonpath='{.data.env}' 2>/dev/null || true)"
[[ -z "$IDENT" || "$IDENT" == local ]] \
  || { echo "REFUSED: cluster at $SERVER identifies as env='$IDENT' (kube-system/dr-cluster-identity) — not a local test cluster." >&2; exit 2; }
# Pods (10.42.0.0/16) → test containers (172.30.0.0/24): Docker's FORWARD policy drops it; DOCKER-USER is the supported hook.
if command -v iptables >/dev/null && iptables -S DOCKER-USER >/dev/null 2>&1; then
  iptables -C DOCKER-USER -s 10.42.0.0/16 -d 172.30.0.0/24 -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER -s 10.42.0.0/16 -d 172.30.0.0/24 -j ACCEPT
  iptables -C DOCKER-USER -s 172.30.0.0/24 -d 10.42.0.0/16 -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER -s 172.30.0.0/24 -d 10.42.0.0/16 -j ACCEPT
  iptables -t raw -C PREROUTING -s 10.42.0.0/16 -d 172.30.0.0/24 -j ACCEPT 2>/dev/null || iptables -t raw -I PREROUTING -s 10.42.0.0/16 -d 172.30.0.0/24 -j ACCEPT
fi

log "helm: External Secrets Operator (→ LocalStack) and Stakater Reloader (repo values file)"
helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
helm repo add stakater https://stakater.github.io/stakater-charts >/dev/null 2>&1 || true
helm repo update >/dev/null
# a previous down.sh may leave ESO CRDs terminating; helm would then skip them and they vanish → wait them out first
for _ in $(seq 1 60); do
  [[ -z "$(K get crd -o jsonpath='{range .items[?(@.metadata.deletionTimestamp)]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep external-secrets.io)" ]] && break; sleep 3
done
eso_install() { helm --kube-context dr-local upgrade --install external-secrets external-secrets/external-secrets -n external-secrets --create-namespace \
  --set installCRDs=true --set-string "extraEnv[0].name=AWS_SECRETSMANAGER_ENDPOINT,extraEnv[0].value=http://$IP_LS:4566" \
  --set-string "extraEnv[1].name=AWS_STS_ENDPOINT,extraEnv[1].value=http://$IP_LS:4566" --wait --timeout 10m >/dev/null; }
eso_install
helm --kube-context dr-local upgrade --install reloader stakater/reloader -n reloader --create-namespace \
  -f "$ROOT/automation/k8s/reloader-values.yaml" \
  --set-string reloader.deployment.env.secret.ALERT_ON_RELOAD=true \
  --set-string reloader.deployment.env.secret.ALERT_WEBHOOK_URL=http://reloader-alert-sink.reloader.svc:8080/ \
  --set-string reloader.deployment.env.secret.ALERT_ADDITIONAL_INFO="cluster=dr-local env=local" \
  --wait --timeout 10m >/dev/null      # alerts → test sink (tests/local/k8s/33-reloader-alert-sink.yaml)
helm --kube-context dr-local list -A

log "cluster identity, ESO store, sample apps"
# after a down.sh the old CRDs can still be terminating while helm installs → wait until they exist again
for try in 1 2; do
  for _ in $(seq 1 20); do K get crd externalsecrets.external-secrets.io secretstores.external-secrets.io >/dev/null 2>&1 && break 2; sleep 3; done
  log "ESO CRDs missing after install (old ones were terminating) → helm upgrade again (try $try)"; eso_install
done
K wait --for condition=established --timeout=180s crd/externalsecrets.external-secrets.io crd/secretstores.external-secrets.io >/dev/null
for _ in 1 2 3 4 5 6; do K apply -f "$HERE/k8s/" >/dev/null && break; sleep 10; done   # webhook may need a few seconds
K -n app wait --for=condition=Ready externalsecret/app-db-credentials --timeout=180s \
  || { echo "ExternalSecret not ready — pod→LocalStack network? (see tests/README.md, constrained hosts)"; exit 1; }
K -n app rollout status deploy/app-a --timeout=180s; K -n app rollout status statefulset/app-b --timeout=180s; K -n app rollout status deploy/app-c --timeout=180s

log "env profile for the scripts → $STATE/local.env"
cat > "$STATE/local.env" <<ENV
# generated by tests/local/up.sh — DR_ENV=local profile (same variables as env/<env>.env.example)
export DR_ENV=local
export AWS_CONFIG_FILE="$STATE/aws-config" AWS_SHARED_CREDENTIALS_FILE="$STATE/aws-credentials"
export AWS_PROFILE=dr-local AWS_REGION=eu-west-1 ACCOUNT_ID=000000000000
export KUBECONFIG="$STATE/kubeconfig" EKS_CONTEXT=dr-local REQUIRE_CLUSTER_IDENTITY=true
export PRIMARY_DB=app-pg-local REPLICA_DB=app-pg-local-replica MULTI_AZ=false BACKUP_RETENTION_DAYS=7
export BASELINE_DIR=$STATE/baselines
export DB_NAME=app APP_DB_USER=app_user
export SECRET_ID=local/app/db SECRET_ID_RO= MASTER_SECRET_ID=local/app/db-master
export K8S_NS=app K8S_SECRET=app-db-credentials K8S_HOST_KEY=POSTGRES_DB_HOST
export DR_SELECTOR='dr.example.com/db-consumer=true'
export QUARANTINE_SG=$QSG DB_SG= DB_SUBNET_GROUP= DB_PARAM_GROUP= DB_INSTANCE_CLASS=
export EVIDENCE_BUCKET=org-dr-evidence-000000000000
export RTO_TARGET_MIN=30 RPO_TARGET_S=86400 REPLICA_LAG_MAX_S=300
export VERIFY_TABLES="public.orders public.payments"
export DR_ENDPOINT_MAP="$STATE/endpoint-map" DR_PGSSLMODE=disable RELOADER_GRACE_S=60
ENV
echo "UP. Next: tests/local/run-tests.sh"
