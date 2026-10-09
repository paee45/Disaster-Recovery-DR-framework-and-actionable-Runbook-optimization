#!/usr/bin/env bash
# tf.sh — run one Terraform stack of the sandbox with its own state in S3.
# Usage and rules: iac/README.md.  Quick help: iac/tf.sh --help
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
die() { echo "tf.sh: $*" >&2; exit 2; }

usage() {
  cat <<'EOF'
Usage:  iac/tf.sh status
        iac/tf.sh <stack> [env] <terraform command…>      (everything after the stack/env goes to terraform)

Stacks (state key = <project>/<env or shared>/<component>/terraform.tfstate):
  platform/state-bucket   platform/terrakube   platform/terrakube-config      shared by all envs
  lab/network   lab/eks   lab/addons                                           shared by all envs
  lab/db <env>  lab/app <env>                                                  env = dev | uat | prod

Examples:
  iac/tf.sh status                          what exists: state in S3 + resources in AWS, per stack
  iac/tf.sh lab/network plan -out=n.plan    read the plan, then:  iac/tf.sh lab/network apply n.plan
  iac/tf.sh lab/db uat apply d.plan
  iac/tf.sh lab/db uat stop | start         stop/start the RDS instance (saves cost; no Terraform change)
  iac/tf.sh lab/eks apply -var node_desired_size=0     park the nodes

Settings: iac/sandbox.env (git-ignored). Override the stop in the "no state but resources exist" guard: TF_ADOPT=1
EOF
}
[[ $# -ge 1 && "$1" != -h && "$1" != --help ]] || { usage; exit 0; }

# ── Settings ──────────────────────────────────────────────────────────────────
cfg="${TF_SANDBOX_ENV:-$HERE/sandbox.env}"
[[ -f "$cfg" ]] || die "missing $cfg — copy iac/sandbox.env.example and fill it in"
# shellcheck disable=SC1090
source "$cfg"
for v in TF_VAR_account_id TF_VAR_aws_profile TF_VAR_region TF_VAR_state_bucket; do
  [[ -n "${!v:-}" ]] || die "$v is empty in $cfg"
done
profile="$TF_VAR_aws_profile"; region="$TF_VAR_region"; bucket="$TF_VAR_state_bucket"
lab_name="dr-lab"; platform_name="dr-platform"      # default resource-name prefixes of the stacks

awsx() { aws --profile "$profile" --region "$region" "$@"; }
state_key() { echo "${1%%/*}/$2/${1#*/}/terraform.tfstate"; }      # <stack> <env|shared>

# ── Login: the named profile may use SSO, an assumed role, credential_process or a static key ──────────
# Same rule as the DR scripts: only the NAMED profile is used; keys exported in the shell are refused (they can point at
# any account). TF_AUTH_ALLOWED (sandbox.env) limits the kinds; a real PROD account should allow only sso,role.
if [[ -n "${AWS_ACCESS_KEY_ID:-}${AWS_SECRET_ACCESS_KEY:-}${AWS_SESSION_TOKEN:-}" ]]; then
  die "AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN are set in this shell: unset them (profile $profile is used)"
fi
unset AWS_DEFAULT_PROFILE

profile_type() {   # <profile> → sso | process | role | key | none
  local p="$1" k
  for k in sso_session sso_start_url; do
    [[ -n "$(aws configure get "$k" --profile "$p" 2>/dev/null)" ]] && { echo sso; return; }
  done
  [[ -n "$(aws configure get credential_process --profile "$p" 2>/dev/null)" ]] && { echo process; return; }
  [[ -n "$(aws configure get role_arn --profile "$p" 2>/dev/null)" ]] && { echo role; return; }
  [[ -n "$(aws configure get aws_access_key_id --profile "$p" 2>/dev/null)" ]] && { echo key; return; }
  echo none
}
auth="$(profile_type "$profile")"
[[ "$auth" != none ]] || die "profile '$profile' is not configured in ~/.aws/config or ~/.aws/credentials (see iac/README.md, \"AWS login\")"
[[ ",${TF_AUTH_ALLOWED:-sso,role,process,key}," == *",$auth,"* ]] \
  || die "profile '$profile' uses '$auth' credentials; allowed here: ${TF_AUTH_ALLOWED:-sso,role,process,key} (TF_AUTH_ALLOWED)"

if ! awsx sts get-caller-identity >/dev/null 2>&1; then
  login="$profile"                                   # SSO login is for an SSO profile, or the SSO profile a role chains on
  if [[ "$auth" == role ]]; then login="$(aws configure get source_profile --profile "$profile" 2>/dev/null || true)"; fi
  if [[ -n "$login" && "$(profile_type "$login")" == sso ]]; then
    aws sso login --profile "$login" || die "SSO login failed"       # the browser opens; the script waits and continues
    awsx sts get-caller-identity >/dev/null 2>&1 || die "credentials of profile '$profile' are still not valid after the login"
  else
    die "credentials of profile '$profile' ($auth) were rejected: check the access key / role / MFA token (nothing to log in to)"
  fi
fi

# ── What does AWS already hold for a stack? (read-only; prints a short text, or nothing) ───────────────
# addons, terrakube-config and state-bucket have nothing to probe.
probe() {   # <stack> <env>
  local out=""
  case "$1" in
    platform/terrakube)
      out="$(awsx ec2 describe-instances --filters "Name=tag:Name,Values=$platform_name-terrakube" \
        Name=instance-state-name,Values=pending,running,stopping,stopped \
        --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)"
      [[ -n "$out" ]] && out="EC2 instance $out" ;;
    lab/network)
      out="$(awsx ec2 describe-vpcs --filters "Name=tag:Name,Values=$lab_name" \
        --query 'Vpcs[].VpcId' --output text 2>/dev/null || true)"
      [[ -n "$out" ]] && out="VPC $out" ;;
    lab/eks)
      out="$(awsx eks describe-cluster --name "$lab_name-eks" --query cluster.status --output text 2>/dev/null || true)"
      [[ -n "$out" ]] && out="EKS cluster $lab_name-eks ($out)" ;;
    lab/db)
      out="$(awsx rds describe-db-instances --db-instance-identifier "$lab_name-$2-pg" \
        --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || true)"
      [[ -n "$out" ]] && out="RDS instance $lab_name-$2-pg ($out)" ;;
    lab/app)
      out="$(awsx rds describe-db-snapshots --db-snapshot-identifier "$lab_name-$2-seed" \
        --query 'DBSnapshots[0].Status' --output text 2>/dev/null || true)"
      [[ -n "$out" ]] && out="RDS snapshot $lab_name-$2-seed ($out)" ;;
  esac
  echo "$out"
}
has_probe() { [[ "$1" =~ ^(platform/terrakube|lab/network|lab/eks|lab/db|lab/app)$ ]]; }

# ── `status`: one table for every stack ───────────────────────────────────────────────────────────────
status() {
  local hb
  if ! hb="$(awsx s3api head-bucket --bucket "$bucket" 2>&1)"; then
    case "$hb" in
      *"(403)"*|*Forbidden*) echo "State bucket $bucket exists, but profile $profile is not allowed to read it (403): check its S3 permissions." ;;
      *"(404)"*|*"Not Found"*) echo "State bucket $bucket does not exist."
         echo "First run:  iac/tf.sh platform/state-bucket plan -out=b.plan   then   apply b.plan" ;;
      *) echo "Cannot reach the state bucket $bucket with profile $profile: $hb" ;;
    esac
    return
  fi
  printf '%-26s %-7s %-14s %-17s %s\n' STACK ENV "STATE IN S3" MODIFIED "AWS / NOTE"
  local row s e k meta n st mod found note
  for row in platform/state-bucket:shared platform/terrakube:shared platform/terrakube-config:shared \
             lab/network:shared lab/eks:shared lab/addons:shared \
             lab/db:dev lab/db:uat lab/db:prod lab/app:dev lab/app:uat lab/app:prod; do
    s="${row%%:*}"; e="${row##*:}"; k="$(state_key "$s" "$e")"
    meta="$(awsx s3api head-object --bucket "$bucket" --key "$k" --query '[LastModified]' --output text 2>/dev/null || true)"
    if [[ -n "$meta" ]]; then
      n="$(awsx s3 cp "s3://$bucket/$k" - 2>/dev/null | jq '[.resources[].instances | length] | add // 0' 2>/dev/null || echo '?')"
      st="yes ($n res.)"; mod="$(echo "$meta" | cut -c1-16 | tr T ' ')"
    else
      st="no"; mod="-"
    fi
    found=""; has_probe "$s" && found="$(probe "$s" "$e")"
    if   [[ "$s" == platform/state-bucket ]]; then note="the bucket itself"
    elif ! has_probe "$s";                    then note="(not probed)"
    elif [[ "$st" == no && -n "$found" ]];    then note="ORPHAN: $found has no state here (see iac/README.md)"
    elif [[ "$st" != no && -z "$found" ]];    then note="state exists, nothing found in AWS (destroyed? run plan)"
    elif [[ -n "$found" ]];                   then note="$found"
    else                                           note="not built"
    fi
    printf '%-26s %-7s %-14s %-17s %s\n' "$s" "$e" "$st" "$mod" "$note"
  done
}
if [[ "$1" == status ]]; then status; exit 0; fi

# ── Arguments: <stack> [env] <terraform command…> ─────────────────────────────────────────────────────
(( $# >= 2 )) || die "usage: tf.sh <stack> [env] <terraform command…>   (tf.sh --help)"
stack="${1%/}"; shift
[[ -d "$HERE/$stack" ]] || die "no such stack: $stack"
case "$stack" in
  lab/db|lab/app)        # per-env stacks take the env as the next word
    env="${1:-}"; [[ "$env" =~ ^(dev|uat|prod)$ ]] || die "$stack needs an env: dev | uat | prod"
    shift; export TF_VAR_env="$env"; stack_env="$stack $env" ;;
  *) env="shared"; stack_env="$stack" ;;
esac
(( $# >= 1 )) || die "missing terraform command (plan, apply, destroy, output …)"
tf() { terraform -chdir="$HERE/$stack" "$@"; }

# ── Where does the state live?  S3 is the source of truth ─────────────────────────────────────────────
#   state already in S3 → use it; a leftover local terraform.tfstate is set aside (never merged, never asked about)
#   no state in S3 yet  → an existing local terraform.tfstate seeds S3 (initial setup); no local file = fresh stack
#   platform/state-bucket runs on a local backend (override file) until its bucket exists; the next run copies it in.
key="$(state_key "$stack" "$env")"
local_state="$HERE/$stack/terraform.tfstate"
boot="$HERE/$stack/zz_bootstrap_override.tf"
state_here="n/a"        # present | absent | seeded | n/a (bootstrap)

s3_state() {   # present | absent; any other error (login, permissions, network) stops instead of guessing
  local out
  out="$(awsx s3api head-object --bucket "$bucket" --key "$key" 2>&1)" && { echo present; return; }
  [[ "$out" == *"Not Found"* || "$out" == *"(404)"* ]] && { echo absent; return; }
  die "cannot check s3://$bucket/$key: $out"
}

if [[ "$stack" == platform/state-bucket ]]; then
  if awsx s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
    rm -f "$boot"
  else
    printf 'terraform {\n  backend "local" {}\n}\n' > "$boot"
  fi
fi

if [[ -f "$boot" ]]; then
  tf init -reconfigure -input=false >/dev/null
  echo "state: local (bootstrap) — the next run moves it to s3://$bucket/$key" >&2
else
  init_mode=(-reconfigure)
  state_here="$(s3_state)"
  if [[ "$state_here" == present ]]; then
    if [[ -s "$local_state" ]]; then
      mv "$local_state" "$local_state.local-$(date +%Y%m%d%H%M%S).bak"
      echo "note: state already in S3; the local terraform.tfstate was set aside as *.bak" >&2
    fi
  elif [[ -s "$local_state" ]]; then
    init_mode=(-migrate-state -force-copy); state_here="seeded"
    echo "note: no state in S3 yet; copying the local terraform.tfstate into it" >&2
  fi
  tf init "${init_mode[@]}" -input=false \
    -backend-config="bucket=$bucket" -backend-config="key=$key" \
    -backend-config="region=$region" -backend-config="profile=$profile" \
    -backend-config="encrypt=true" -backend-config="use_lockfile=true" >/dev/null
  echo "state: s3://$bucket/$key" >&2
fi

# ── Guard: no state in S3, but AWS already holds the stack's resources ────────────────────────────────
# Terraform does not know them. `plan` only warns; `apply` and `destroy` stop (override: TF_ADOPT=1).
if [[ "$state_here" == absent ]]; then
  found="$(probe "$stack" "$env")"
  if [[ -n "$found" ]]; then
    level=WARNING; blocked=0
    if [[ "$1" =~ ^(apply|destroy)$ && "${TF_ADOPT:-}" != 1 ]]; then level=STOP; blocked=1; fi
    cat >&2 <<EOF

$level: AWS already has $found, but there is no state for it in S3 (s3://$bucket/$key).
Terraform does not know these resources. An apply would fail with "already exists" or leave a duplicate.

Choose one:
  1. Restore the state      an earlier object version in the bucket, or the right key; then run again
  2. Import the resources   keep them:  iac/tf.sh $stack_env import <address> <id>   then plan until "No changes"
  3. Delete and rebuild     throw-away lab only: iac/lab/README.md, "Destroy"

More: iac/README.md, "Resources exist but there is no state". Import workflow override: TF_ADOPT=1

EOF
    (( blocked == 0 )) || exit 3
  fi
fi

# ── Inputs computed per run ───────────────────────────────────────────────────────────────────────────
# lab/app writes env/<env>.env into this repo (only meaningful on the Mac, never inside Terrakube).
if [[ "$stack" == lab/app ]]; then export TF_VAR_write_env_file="${TF_VAR_write_env_file:-true}"; fi
# Postgres is reachable from outside the VPC only from this /32: use your current public IP unless set.
if [[ "$stack" =~ ^(lab/db|platform/terrakube-config)$ && -z "${TF_VAR_operator_cidr:-}" ]]; then
  ip="$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')" || die "cannot detect your public IP"
  export TF_VAR_operator_cidr="$ip/32"
fi

# ── Run ───────────────────────────────────────────────────────────────────────────────────────────────
case "$1" in
  stop|start)
    [[ "$stack" == lab/db ]] || die "stop/start only exist for lab/db"
    id="$(tf output -raw db_identifier)"
    awsx rds "$1-db-instance" --db-instance-identifier "$id" \
      --query 'DBInstance.[DBInstanceIdentifier,DBInstanceStatus]' --output text
    [[ "$1" == stop ]] && echo "note: RDS starts a stopped instance again by itself after 7 days." ;;
  *) tf "$@" ;;
esac
