#!/usr/bin/env bash
# destroy-all.sh — tear down what is built of the DR lab, in the safe order, one confirmed plan per stack.
# Guide: iac/lab/README.md ("Destroy"). Never touches platform/* (state bucket, Terrakube).
#
#   iac/lab/destroy-all.sh [--env dev|uat|prod]... [--keep-shared] [--plan-only]
#
#   --env E         envs to remove (repeatable). Default: dev and uat. prod only when named, and then you type "prod".
#   --keep-shared   remove only lab/app + lab/db of the chosen envs; keep lab/addons, lab/eks, lab/network.
#   --plan-only     show the destroy plan of every deployed stack, apply nothing.
#
# Order: app → db → addons → eks → network. A stack with no resources in its S3 state is skipped, and a shared stack is
# kept while something that needs it is still deployed (cluster: any app; network: any db, eks or addons).
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"          # iac/
TF="$HERE/tf.sh"
die() { echo "destroy-all.sh: $*" >&2; exit 2; }

envs=(); keep_shared=0; plan_only=0
while (( $# )); do
  case "$1" in
    --env)         [[ "${2:-}" =~ ^(dev|uat|prod)$ ]] || die "--env needs dev, uat or prod"; envs+=("$2"); shift 2 ;;
    --keep-shared) keep_shared=1; shift ;;
    --plan-only)   plan_only=1; shift ;;
    -h|--help)     sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1 (--help)" ;;
  esac
done
(( ${#envs[@]} )) || envs=(dev uat)

cfg="${TF_SANDBOX_ENV:-$HERE/sandbox.env}"
[[ -f "$cfg" ]] || die "missing $cfg"
# shellcheck disable=SC1090
source "$cfg"
profile="$TF_VAR_aws_profile"; region="$TF_VAR_region"; bucket="$TF_VAR_state_bucket"; lab="dr-lab"
awsx() { aws --profile "$profile" --region "$region" "$@"; }

plans="$(mktemp -d)"; trap 'rm -rf "$plans"' EXIT       # plan files can hold secrets: never left on disk

# ── What is deployed? (resources in the S3 state of the stack; also logs in via tf.sh status) ─────────
echo "Current state of the lab:"; "$TF" status || die "status failed (login?)"; echo
held() {   # <stack> <env|shared> → number of resources in the state (0 = none or no state)
  local key="${1%%/*}/$2/${1#*/}/terraform.tfstate"
  awsx s3 cp "s3://$bucket/$key" - 2>/dev/null | jq '[.resources[].instances | length] | add // 0' 2>/dev/null || echo 0
}

confirm() {   # <question> [word to type]
  local a
  if [[ -n "${2:-}" ]]; then read -r -p "$1 Type '$2' to continue, anything else skips: " a; [[ "$a" == "$2" ]]
  else read -r -p "$1 [y/N] " a; [[ "$a" =~ ^[yY]$ ]]; fi
}

# ── Restores made by the DR scripts are not in Terraform and block the subnet group / SGs ─────────────
delete_restores() {   # <env>
  local db list
  list="$(awsx rds describe-db-instances --query "DBInstances[?starts_with(DBInstanceIdentifier,\`$lab-$1-pg-\`)].DBInstanceIdentifier" --output text)"
  [[ -n "$list" ]] || return 0
  echo "Restored instances of $1 (made by the DR scripts, not in Terraform): $list"
  confirm "Delete them (no final snapshot)?" || { echo "kept; the db destroy will fail while they use the subnet group"; return 0; }
  for db in $list; do
    awsx rds modify-db-instance --db-instance-identifier "$db" --no-deletion-protection --apply-immediately >/dev/null
    awsx rds delete-db-instance --db-instance-identifier "$db" --skip-final-snapshot --delete-automated-backups >/dev/null
    awsx rds wait db-instance-deleted --db-instance-identifier "$db" && echo "deleted $db"
  done
}

# ── One stack: plan destroy to a file, show what goes, ask, apply that file ───────────────────────────
destroy_stack() {   # <stack> <env|shared>
  local stack="$1" env="$2" args=() label plan n
  [[ "$env" == shared ]] || args=("$env")
  label="$stack${args[*]:+ ${args[*]}}"
  n="$(held "$stack" "$env")"
  if (( n == 0 )); then echo "- $label: nothing deployed, skipped"; return 0; fi
  echo; echo "=== $label ($n resources in state) ==="
  if [[ "$stack" == lab/db ]]; then
    [[ "$(awsx rds describe-db-instances --db-instance-identifier "$lab-$env-pg" --query 'DBInstances[0].DeletionProtection' --output text 2>/dev/null)" == True ]] \
      && die "$lab-$env-pg has deletion protection: run  iac/tf.sh lab/db $env apply -var deletion_protection=false  first"
    delete_restores "$env"
  fi
  plan="$plans/${stack//\//-}-$env.plan"
  "$TF" "$stack" ${args[@]+"${args[@]}"} plan -destroy -input=false -no-color -out="$plan" | grep -E '^  # |^Plan:|^Error|^│' \
    || true
  [[ -s "$plan" ]] || die "no plan was written for $label: see the error above"
  (( plan_only == 0 )) || return 0
  if [[ "$env" == prod ]]; then confirm "DESTROY PROD $stack?" prod || { echo "skipped $label"; return 1; }
  else confirm "Destroy $label?" || { echo "skipped $label"; return 1; }; fi
  "$TF" "$stack" ${args[@]+"${args[@]}"} apply -input=false "$plan" || die "destroy of $label failed; fix it and run this script again (it skips what is gone)"
}

# ── Run, in order ──────────────────────────────────────────────────────────────────────────────────────
for e in "${envs[@]}"; do destroy_stack lab/app "$e" || true; done
for e in "${envs[@]}"; do destroy_stack lab/db "$e" || true; done

if (( keep_shared )); then echo; echo "Shared stacks kept (--keep-shared)."; exit 0; fi

apps=0; for e in dev uat prod; do apps=$(( apps + $(held lab/app "$e") )); done
if (( apps > 0 )); then
  echo; echo "Kept lab/addons, lab/eks, lab/network: lab/app is still deployed in another env (use --env for it)."; exit 0
fi
destroy_stack lab/addons shared || true
destroy_stack lab/eks shared || true

rest=$(( $(held lab/addons shared) + $(held lab/eks shared) ))
for e in dev uat prod; do rest=$(( rest + $(held lab/db "$e") )); done
if (( rest > 0 )); then
  echo; echo "Kept lab/network: something that uses it is still deployed (db, eks or addons)."; exit 0
fi
destroy_stack lab/network shared || true
echo; echo "Done. Check:  iac/tf.sh status"
