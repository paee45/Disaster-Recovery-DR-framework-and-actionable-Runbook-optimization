#!/usr/bin/env bash
# tf.sh — run one Terraform stack of the sandbox with its own S3 state (key = <project>/<env>/<component>).
#
#   iac/tf.sh platform/state-bucket apply        # bootstrap, LOCAL state (creates the state bucket once)
#   iac/tf.sh platform/terrakube plan            # state: platform/shared/terrakube
#   iac/tf.sh platform/terrakube migrate         # copy an existing local state into S3
#   iac/tf.sh platform/terrakube-config apply    # Terrakube org, templates, one workspace per lab stack (tunnel open)
#   iac/tf.sh lab/network apply                  # state: lab/shared/network
#   iac/tf.sh lab/eks apply                      # state: lab/shared/eks        (-var node_desired_size=0 parks the nodes)
#   iac/tf.sh lab/addons apply                   # state: lab/shared/addons     (Reloader + cluster identity)
#   iac/tf.sh lab/db uat apply                   # state: lab/uat/db            (dev | uat | prod, one state each)
#   iac/tf.sh lab/app uat apply                  # state: lab/uat/app
#   iac/tf.sh lab/db uat stop|start              # stop/start the RDS instance (no Terraform change) to save cost
#   iac/tf.sh lab/db uat destroy                 # remove just this component
# Anything after the stack (and env) is passed to terraform unchanged. Settings: iac/sandbox.env (git-ignored).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
die() { echo "tf.sh: $*" >&2; exit 2; }

(( $# >= 2 )) || { sed -n '2,15p' "$0"; exit 2; }
stack="${1%/}"; shift
[[ -d "$HERE/$stack" ]] || die "no such stack: $stack"

cfg="${TF_SANDBOX_ENV:-$HERE/sandbox.env}"
[[ -f "$cfg" ]] || die "missing $cfg — copy iac/sandbox.env.example and fill it in"
# shellcheck disable=SC1090
source "$cfg"
for v in TF_VAR_account_id TF_VAR_aws_profile TF_VAR_region TF_VAR_state_bucket; do
  [[ -n "${!v:-}" ]] || die "$v is empty in $cfg"
done
profile="$TF_VAR_aws_profile"; region="$TF_VAR_region"

# Per-env stacks take the env as the 2nd word; every other stack is shared by all envs.
case "$stack" in
  lab/db|lab/app)
    env="${1:-}"; [[ "$env" =~ ^(dev|uat|prod)$ ]] || die "$stack needs an env: dev | uat | prod"
    shift; export TF_VAR_env="$env" ;;
  *) env="shared" ;;
esac
(( $# >= 1 )) || die "missing terraform command (plan, apply, destroy, output ...)"

# SSO login on demand (the browser opens; this script waits and continues).
if ! aws --profile "$profile" --region "$region" sts get-caller-identity >/dev/null 2>&1; then
  aws sso login --profile "$profile" || die "SSO login failed"
fi

tf() { terraform -chdir="$HERE/$stack" "$@"; }

# Every stack keeps its state in S3 (key = <project>/<env>/<component>). Two moves copy an existing LOCAL state in:
#  • `migrate` (e.g. platform/terrakube, whose state started on this Mac)
#  • platform/state-bucket: before its bucket exists it runs on a local backend (override file); the first run
#    after the bucket exists moves that state into the bucket it created.
key="${stack%%/*}/$env/${stack#*/}/terraform.tfstate"
init_mode=(-reconfigure)
[[ "$1" == migrate ]] && init_mode=(-migrate-state -force-copy)
if [[ "$stack" == platform/state-bucket ]]; then
  boot="$HERE/$stack/zz_bootstrap_override.tf"
  if aws --profile "$profile" --region "$region" s3api head-bucket --bucket "$TF_VAR_state_bucket" >/dev/null 2>&1; then
    [[ -f "$boot" ]] && { rm -f "$boot"; init_mode=(-migrate-state -force-copy); }
  else
    printf 'terraform {\n  backend "local" {}\n}\n' > "$boot"
  fi
fi
if [[ -f "$HERE/$stack/zz_bootstrap_override.tf" ]]; then
  tf init -reconfigure -input=false >/dev/null          # bucket not created yet: local state
  echo "state: local (bootstrap) — the next run moves it to s3://$TF_VAR_state_bucket/$key" >&2
else
  tf init "${init_mode[@]}" -input=false \
    -backend-config="bucket=$TF_VAR_state_bucket" -backend-config="key=$key" \
    -backend-config="region=$region" -backend-config="profile=$profile" \
    -backend-config="encrypt=true" -backend-config="use_lockfile=true" >/dev/null
  echo "state: s3://$TF_VAR_state_bucket/$key" >&2
fi
[[ "$1" == migrate ]] && exit 0

# Postgres is reachable from outside the VPC only from this /32 — take the current public IP unless set.
if [[ "$stack" =~ ^(lab/db|platform/terrakube-config)$ && -z "${TF_VAR_operator_cidr:-}" ]]; then
  ip="$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')" || die "cannot detect your public IP"
  export TF_VAR_operator_cidr="$ip/32"
fi

case "$1" in
  stop|start)
    [[ "$stack" == lab/db ]] || die "stop/start only exist for lab/db"
    id="$(tf output -raw db_identifier)"
    aws --profile "$profile" --region "$region" rds "$1-db-instance" --db-instance-identifier "$id" \
      --query 'DBInstance.[DBInstanceIdentifier,DBInstanceStatus]' --output text
    [[ "$1" == stop ]] && echo "note: RDS starts a stopped instance again by itself after 7 days." ;;
  *) tf "$@" ;;
esac
