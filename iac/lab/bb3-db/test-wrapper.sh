#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

source() {
  export TF_VAR_account_id=000000000000
  export TF_VAR_aws_profile="${TEST_PROFILE:-lab_sandbox}"
  export TF_VAR_region="${TEST_REGION:-ap-southeast-1}"
  export TF_VAR_state_bucket=sandbox-offline-state
  export TF_VAR_operator_cidr="${TEST_CIDR-203.0.113.10/32}"
}
git() { [[ "${TEST_IGNORED:-yes}" == yes ]]; }
aws() {
  case "$*" in
    *"configure get sso_session"*)
      [[ "${TEST_AUTH:-sso}" != sso ]] || printf '%s\n' offline-session ;;
    *"configure get aws_access_key_id"*) printf '%s\n' offline-placeholder ;;
    *"configure get"*) return 0 ;;
    *"sts get-caller-identity"*) printf '%s\n' "${TEST_ACCOUNT:-000000000000}" ;;
    *"s3api head-object"*) printf '%s\n' '(404) Not Found' >&2; return 1 ;;
    *"rds describe-db-instances"*) return 0 ;;
    *) printf '%s\n' "Unexpected AWS stub call: $*" >&2; return 99 ;;
  esac
}
terraform() { printf 'TERRAFORM_STUB %s\n' "$*" >&2; }
curl() { printf '%s\n' 'Unexpected curl stub call' >&2; return 99; }
export -f source git aws terraform curl
export TF_SANDBOX_ENV="$HERE/test-wrapper.sh"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

check() {
  local expected_code="$1" expected_text="$2" output exit_code
  shift 2
  exit_code=0
  output="$(bash "$ROOT/tf.sh" "$@" 2>&1)" || exit_code=$?
  [[ "$exit_code" == "$expected_code" && "$output" == *"$expected_text"* ]] || {
    printf 'FAIL: %s (exit %s)\n%s\n' "$*" "$exit_code" "$output" >&2
    exit 1
  }
  if [[ "$expected_code" != 0 && "$output" == *TERRAFORM_STUB* ]]; then
    printf '%s\n' 'FAIL: refused command reached Terraform stub' >&2
    exit 1
  fi
  printf 'PASS: %s\n' "$expected_text"
}

check 0 'key=lab/uat/bb3-db/terraform.tfstate' lab/bb3-db uat plan -out=bb3.plan
check 0 'key=lab/dev/bb3-db/terraform.tfstate' lab/bb3-db dev plan -out=bb3.plan
check 0 'key=lab/prod/bb3-db/terraform.tfstate' lab/bb3-db prod plan -out=bb3.plan
check 0 'allowed_account_ids=["000000000000"]' lab/bb3-db uat plan -out=bb3.plan
check 0 '-var=account_id=000000000000 -var=aws_profile=lab_sandbox -var=region=ap-southeast-1 -var=state_bucket=sandbox-offline-state -var=env=uat' lab/bb3-db uat plan -out=bb3.plan -var=account_id=111111111111
check 0 'key=lab/uat/db/terraform.tfstate' lab/db uat plan -out=db.plan
check 2 'needs an env' lab/bb3-db real plan
check 2 'cannot be stopped for fencing' lab/bb3-db uat stop
check 2 'cannot be stopped for fencing' lab/bb3-db uat start
check 2 'teardown requires plan -destroy' lab/bb3-db uat destroy
check 2 'apply requires one existing stack-local .plan' lab/bb3-db uat apply -auto-approve
TEST_PROFILE=other check 2 'requires lab_sandbox' lab/bb3-db uat plan
TEST_REGION=other check 2 'requires lab_sandbox' lab/bb3-db uat plan
TEST_CIDR='' check 0 'key=lab/uat/bb3-db/terraform.tfstate' lab/bb3-db uat plan -out=bb3.plan
TEST_IGNORED=no check 2 'must be in ignored sandbox config' lab/bb3-db uat plan
TEST_AUTH=key check 2 'requires an SSO' lab/bb3-db uat plan
TEST_PROFILE=pa_aws_sandbox TEST_AUTH=key check 0 '-var=aws_profile=pa_aws_sandbox' lab/bb3-db uat plan -out=bb3.plan
TEST_PROFILE=pa_aws_sandbox TEST_AUTH=sso check 2 'requires an IAM-key' lab/bb3-db uat plan
TEST_PROFILE=pa_aws_sandbox TEST_AUTH=key TEST_ACCOUNT=mismatch check 2 'account does not match' lab/bb3-db uat plan
TEST_ACCOUNT=mismatch check 2 'account does not match' lab/bb3-db uat plan