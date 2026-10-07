#!/usr/bin/env bash
# dr-env-discover.sh — build env/<env>.env from what exists in AWS and the cluster, so nothing is looked up by hand.
# Read-only: it only describes/lists (RDS, Secrets Manager, EC2 security groups, S3, EKS) and, if the kube context
# exists, lists Secret NAMES and KEYS (never values). It copies env/<env>.env.example and replaces what it finds.
#
# Usage:  ./automation/scripts/dr-env-discover.sh <dev|uat|prod> --profile <named-profile> --region <region> \
#             [--db <instance-id>] [--cluster <eks-name>] [--context <kube-context>] [--namespace <ns> --secret <name>] \
#             [--kubeconfig <file>] [--out <file>] [--print] [--force]
# Then:   source env/<env>.env && ./automation/scripts/dr-env-check.sh S3
# Anything it cannot find is left empty with a "# TODO" comment and listed at the end (dr-env-check reports it too).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
die() { echo "dr-env-discover: $*" >&2; exit 2; }
say() { printf '%s\n' "$*" >&2; }

# ───────────────────────────── arguments ─────────────────────────────
ENVN="${1:-}"; [[ "$ENVN" =~ ^(dev|uat|prod)$ ]] || die "first argument must be dev, uat or prod (see --help in the header)"; shift
P="${AWS_PROFILE:-}"; R="${AWS_REGION:-}"; DB=""; CLUSTER=""; CTX=""; NS=""; SEC=""; KC=""; OUT=""; PRINT=0; FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) P="$2"; shift 2 ;;      --region) R="$2"; shift 2 ;;
    --db) DB="$2"; shift 2 ;;          --cluster) CLUSTER="$2"; shift 2 ;;
    --context) CTX="$2"; shift 2 ;;    --namespace) NS="$2"; shift 2 ;;
    --secret) SEC="$2"; shift 2 ;;     --kubeconfig) KC="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;        --print) PRINT=1; shift ;;
    --force) FORCE=1; shift ;;         -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -n "$P" && -n "$R" ]] || die "--profile and --region are required (a NAMED profile; no default profile is used)"
[[ -z "${AWS_ACCESS_KEY_ID:-}${AWS_SECRET_ACCESS_KEY:-}${AWS_SESSION_TOKEN:-}" ]] \
  || die "AWS keys are exported in this shell: unset them and use the named profile $P"
for t in aws jq; do command -v "$t" >/dev/null || die "$t is missing"; done
TPL="$ROOT/env/$ENVN.env.example"; [[ -f "$TPL" ]] || die "template $TPL not found"
OUT="${OUT:-$ROOT/env/$ENVN.env}"
if (( ! PRINT )) && [[ -e "$OUT" && $FORCE -eq 0 ]]; then die "$OUT exists — use --force (a .bak copy is kept) or --print"; fi

awsq() { aws --profile "$P" --region "$R" "$@"; }
declare -A V=()          # variable → discovered value
FOUND=(); MISSING=(); INFO=()
found() { V["$1"]="$2"; FOUND+=("$1"); }

# ───────────────────────────── account ─────────────────────────────
if ! ident="$(awsq sts get-caller-identity --output json 2>&1)"; then
  say "cannot use profile $P: $ident"
  say "  SSO profile: aws sso login --profile $P   |   access-key profile: check the key"   # pin-lint: ok (message text)
  exit 2
fi
found AWS_PROFILE "$P"; found AWS_REGION "$R"; found ACCOUNT_ID "$(jq -r .Account <<<"$ident")"
found REPLICA_REGION "$R"       # changed below only if a cross-region replica is found
# The identity guard checks the caller against AWS_ROLE_PATTERN: use the identity that ran this discovery
caller="$(jq -r .Arn <<<"$ident")"
case "$caller" in
  *:assumed-role/AWSReservedSSO_*) rp="${caller#*:assumed-role/}"; rp="assumed-role/${rp%%/*}"; found AWS_ROLE_PATTERN "${rp%_*}_" ;;
  *:assumed-role/*) rp="${caller#*:assumed-role/}"; found AWS_ROLE_PATTERN "assumed-role/${rp%%/*}/" ;;
  *:user/*) found AWS_ROLE_PATTERN "user/${caller##*/}" ;;
esac
say "account $(jq -r .Account <<<"$ident") as $(jq -r .Arn <<<"$ident")"

# ───────────────────────────── RDS primary, replica, tags ─────────────────────────────
if [[ -z "$DB" ]]; then
  # primaries only (no read replicas) whose name contains the env
  mapfile -t cand < <(awsq rds describe-db-instances --output json \
    | jq -r --arg e "$ENVN" '.DBInstances[] | select((.ReadReplicaSourceDBInstanceIdentifier // "") == "")
        | select(.DBInstanceIdentifier | ascii_downcase | contains($e)) | .DBInstanceIdentifier')
  case "${#cand[@]}" in
    1) DB="${cand[0]}" ;;
    0) INFO+=("no RDS primary with '$ENVN' in its name in $R — pass --db <instance-id>") ;;
    *) INFO+=("several RDS primaries match '$ENVN': ${cand[*]} — pass --db <instance-id>") ;;
  esac
fi
if [[ -n "$DB" ]]; then
  dbj="$(awsq rds describe-db-instances --db-instance-identifier "$DB" --query 'DBInstances[0]' --output json 2>/dev/null || true)"
  if [[ -z "$dbj" || "$dbj" == null ]]; then INFO+=("RDS instance $DB not found")
  else
    found PRIMARY_DB "$DB"
    found MULTI_AZ "$(jq -r '.MultiAZ' <<<"$dbj")"
    [[ "$(jq -r '.DBInstanceStatus' <<<"$dbj")" == stopped ]] && found PRIMARY_STOPPED_OK 1
    dbname="$(jq -r '.DBName // empty' <<<"$dbj")"; [[ -n "$dbname" ]] && found DB_NAME "$dbname"
    rep="$(jq -r '.ReadReplicaDBInstanceIdentifiers[0] // empty' <<<"$dbj")"
    if [[ -n "$rep" ]]; then
      if [[ "$rep" == arn:* ]]; then found REPLICA_REGION "$(cut -d: -f4 <<<"$rep")"; rep="${rep##*:db:}"; else found REPLICA_REGION "$R"; fi
      found REPLICA_DB "$rep"
    else found REPLICA_DB ""; fi
    # tags the restored instances need again (AWS-managed aws:* tags cannot be set)
    tags="$(jq -r '[.TagList[]? | select(.Key | startswith("aws:") | not) | "Key=\(.Key),Value=\(.Value)"] | join(" ")' <<<"$dbj")"
    [[ -n "$tags" ]] && found EXTRA_TAGS "$tags" || found EXTRA_TAGS ""
    msec="$(jq -r '.MasterUserSecret.SecretArn // empty' <<<"$dbj")"; [[ -n "$msec" ]] && found MASTER_SECRET_ID "$msec"
    vpc="$(jq -r '.DBSubnetGroup.VpcId // empty' <<<"$dbj")"
    INFO+=("baseline of $DB: class $(jq -r .DBInstanceClass <<<"$dbj"), subnet group $(jq -r '.DBSubnetGroup.DBSubnetGroupName' <<<"$dbj"), SGs $(jq -r '[.VpcSecurityGroups[].VpcSecurityGroupId] | join(",")' <<<"$dbj"), parameter group $(jq -r '.DBParameterGroups[0].DBParameterGroupName' <<<"$dbj") (the restore reads these itself: DB_* stay empty)")
  fi
fi

# ───────────────────────────── Secrets Manager (only needed for SECRET_MODE=eso) ─────────────────────────────
names="$(awsq secretsmanager list-secrets --query 'SecretList[].Name' --output text 2>/dev/null | tr '\t' '\n' || true)"
pick() {   # <var> <grep -E pattern> <grep -vE pattern or ''>  — set only if exactly one name matches
  local m; m="$(grep -iE "$2" <<<"$names" | { [[ -n "${3:-}" ]] && grep -viE "$3" || cat; } || true)"
  [[ -n "$m" && "$(wc -l <<<"$m")" -eq 1 ]] && found "$1" "$m"
}
[[ -z "${V[MASTER_SECRET_ID]:-}" ]] && pick MASTER_SECRET_ID "${ENVN}.*master|master.*${ENVN}" ""
pick SECRET_ID "(^|/)${ENVN}.*/db$|${ENVN}/.*db$" "master|-ro$|readonly"
pick SECRET_ID_RO "${ENVN}.*db-?ro|${ENVN}.*readonly" ""

# ───────────────────────────── quarantine security group, evidence bucket ─────────────────────────────
if [[ -n "${vpc:-}" ]]; then
  q="$(awsq ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc" "Name=group-name,Values=*quarantine*" \
        --query 'SecurityGroups[].GroupId' --output text 2>/dev/null | tr '\t' '\n' || true)"
  [[ -n "$q" && "$(wc -l <<<"$q")" -eq 1 ]] && found QUARANTINE_SG "$q"
fi
eb="$(awsq s3api list-buckets --query 'Buckets[].Name' --output text 2>/dev/null | tr '\t' '\n' | grep -iE 'dr-?evidence' || true)"
[[ -n "$eb" && "$(wc -l <<<"$eb")" -eq 1 ]] && found EVIDENCE_BUCKET "$eb"

# ───────────────────────────── EKS cluster, kube context, the app Secret ─────────────────────────────
if [[ -z "$CLUSTER" ]]; then
  mapfile -t cl < <(awsq eks list-clusters --query 'clusters[]' --output text 2>/dev/null | tr '\t' '\n' | grep -i "$ENVN" || true)
  [[ "${#cl[@]}" -eq 1 ]] && CLUSTER="${cl[0]}" \
    || INFO+=("EKS: ${#cl[@]} cluster(s) with '$ENVN' in the name${cl:+ (${cl[*]})} — pass --cluster <name>")
fi
CTX="${CTX:-dr-$ENVN}"; KC="${KC:-$HOME/.kube/dr-$ENVN.config}"
if [[ -n "$CLUSTER" ]]; then
  found EKS_CLUSTER_NAME "$CLUSTER"; found EKS_CONTEXT "$CTX"
  if [[ ! -f "$KC" ]]; then
    INFO+=("no kubeconfig at $KC — create it, then run this again:  aws eks update-kubeconfig --name $CLUSTER --alias $CTX --kubeconfig $KC --profile $P --region $R")   # pin-lint: ok (message text)
  elif ! command -v kubectl >/dev/null; then INFO+=("kubectl is missing: the Secret/namespace could not be looked up")
  else
    kq() { KUBECONFIG="$KC" kubectl --context "$CTX" --request-timeout=15s "$@"; }
    if [[ -n "$NS" && -n "$SEC" ]]; then cands="$NS/$SEC"
    else   # Secrets that hold a *HOST* key: names and key names only, never values
      cands="$(kq get secrets -A -o json 2>/dev/null \
        | jq -r '.items[] | select(.data != null) | select([.data | keys[] | test("HOST"; "i")] | any)
                 | "\(.metadata.namespace)/\(.metadata.name)"' || true)"
    fi
    if [[ -n "$cands" && "$(wc -l <<<"$cands")" -eq 1 ]]; then
      NS="${cands%%/*}"; SEC="${cands##*/}"
      keys="$(kq -n "$NS" get secret "$SEC" -o json 2>/dev/null | jq -r '.data | keys[]' || true)"
      found K8S_NS "$NS"; found K8S_SECRET "$SEC"
      hk="$(grep -iE 'HOST' <<<"$keys" | paste -sd, -)"; [[ -n "$hk" ]] && found K8S_HOST_KEY "$hk"
      pk="$(grep -iE 'PORT' <<<"$keys" | head -1)"; [[ -n "$pk" ]] && found K8S_PORT_KEY "$pk"
      uk="$(grep -iE 'USER' <<<"$keys" | head -1)"; pw="$(grep -iE 'PASS' <<<"$keys" | head -1)"
      [[ -n "$uk" ]] && found K8S_USER_KEY "$uk"; [[ -n "$pw" ]] && found K8S_PASSWORD_KEY "$pw"
      [[ "$(kq -n kube-system get configmap dr-cluster-identity -o jsonpath='{.data.env}' 2>/dev/null)" == "$ENVN" ]] \
        || INFO+=("kube-system/dr-cluster-identity does not say env=$ENVN (REQUIRE_CLUSTER_IDENTITY=true will refuse): create it per docs/12")
    elif [[ -n "$cands" ]]; then INFO+=("several Secrets hold a HOST key: $(tr '\n' ' ' <<<"$cands")— pass --namespace and --secret")
    else INFO+=("no Secret with a *HOST* key found through context $CTX — pass --namespace and --secret (or check access)")
    fi
  fi
fi

# ───────────────────────────── write the file from the example ─────────────────────────────
quote() { if [[ "$1" =~ ^[A-Za-z0-9_./:,@%+=-]*$ ]]; then printf '%s' "$1"; else printf "'%s'" "${1//\'/\'\\\'\'}"; fi; }
# values the example fills with made-up samples: if not discovered they are blanked and flagged, not left looking real
SAMPLES=" QUARANTINE_SG MASTER_SECRET_ID APP_HEALTH_URLS PRIMARY_DB EKS_CLUSTER_NAME EKS_CONTEXT K8S_NS K8S_SECRET "
# Secrets Manager ids matter only for SECRET_MODE=eso, and a replica is optional: blanked when not found, not a TODO
ESO_ONLY=" SECRET_ID SECRET_ID_RO REPLICA_DB "
render() {
  local line name rest cmt
  while IFS= read -r line; do
    if [[ "$line" =~ ^export[[:space:]]+([A-Z0-9_]+)=(.*)$ ]]; then
      name="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"
      cmt=""; [[ "$rest" == *"   #"* ]] && cmt="   #${rest#*"   #"}"
      if [[ "$name" == K8S_USER_KEY ]]; then      # one line holds both keys in the example
        [[ -n "${V[K8S_USER_KEY]+x}" ]] && line="export K8S_USER_KEY=$(quote "${V[K8S_USER_KEY]}") K8S_PASSWORD_KEY=$(quote "${V[K8S_PASSWORD_KEY]:-POSTGRES_DB_PASSWORD}")"
      elif [[ -n "${V[$name]+x}" ]]; then
        line="export $name=$(quote "${V[$name]}")${cmt}"
      elif [[ "$SAMPLES" == *" $name "* ]]; then
        line="export $name=\"\"   # TODO: not found — fill in${cmt}"; MISSING+=("$name")
      elif [[ "$ESO_ONLY" == *" $name "* ]]; then
        line="export $name=\"\"   # optional: only for SECRET_MODE=eso, or when a replica exists${cmt}"
      fi
    fi
    printf '%s\n' "$line"
  done < "$TPL"
}
if (( PRINT )); then render; else
  [[ -e "$OUT" ]] && cp -p "$OUT" "$OUT.bak"
  { printf '# GENERATED by automation/scripts/dr-env-discover.sh on %s from env/%s.env.example — review every value, then:\n' "$(date -u +%FT%TZ)" "$ENVN"
    printf '#   source %s && ./automation/scripts/dr-env-check.sh S3        (git-ignored; holds no passwords)\n' "env/$ENVN.env"
    render; } > "$OUT"
  chmod 600 "$OUT"
fi

# ───────────────────────────── summary ─────────────────────────────
say ""; say "FOUND (${#FOUND[@]}):"
for v in "${FOUND[@]}"; do say "  $v=${V[$v]}"; done
if (( ${#MISSING[@]} )); then say ""; say "STILL TO FILL IN (${#MISSING[@]}):"; printf '  %s\n' "${MISSING[@]}" >&2; fi
if (( ${#INFO[@]} )); then say ""; say "NOTES:"; printf '  - %s\n' "${INFO[@]}" >&2; fi
(( PRINT )) || { say ""; say "wrote $OUT"; }
