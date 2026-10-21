#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TEMP="$(mktemp -d)"
trap 'if [[ "${KEEP_TEST_TEMP:-}" == 1 ]]; then printf "Test fixture retained at %s\n" "$TEMP"; else rm -rf "$TEMP"; fi' EXIT
CONFIG="$TEMP/sandbox.env"
LEDGER="$TEMP/evidence"
export BB3_SANDBOX_CONFIG="$CONFIG" BB3_LEDGER_DIR="$LEDGER" SCRIPT="$HERE/incident-start.sh"

git() { return 0; }
aws() {
  case "$*" in
    *'sts get-caller-identity'*) printf '%s\n' 000000000000 ;;
    *) printf 'Unexpected AWS call: %s\n' "$*" >&2; return 99 ;;
  esac
}
export -f git aws
export TF_VAR_aws_profile=lab_sandbox TF_VAR_region=ap-southeast-1 TF_VAR_account_id=000000000000 ENV=uat
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
shopt -s nullglob
printf '%s\n' \
  'export TF_VAR_aws_profile=lab_sandbox' \
  'export TF_VAR_region=ap-southeast-1' \
  'export TF_VAR_account_id=000000000000' \
  'export ENV=uat' > "$CONFIG"
printf '%s\n' \
  'export BB3_DR_ID=DR-test' \
  'export BB3_SOURCE_PRIMARY_ID=old-primary' \
  'export BB3_SOURCE_REPLICA_ID=old-replica' >> "$CONFIG"
mkdir -p "$LEDGER/DR-test"
jq -n '{runId:"DR-test",account:"000000000000",region:"ap-southeast-1",activePrimary:"old-primary",activeReplica:"old-replica",status:"attached"}' \
  > "$LEDGER/DR-test/network-fence.json"

run_impact() {
  local t0="$1" ref="$2" script="$TEMP/impact.exp"
  cat > "$script" <<'EOF'
set timeout 10
spawn bash $env(SCRIPT) impact
expect "Current UTC default:"
expect "Impact start T0 from app/monitor evidence"
if {$env(TEST_T0) == ""} { send "\r" } else { send "$env(TEST_T0)\r" }
expect "T0 incident/monitor evidence reference"
send "$env(TEST_REF)\r"
expect "Impact time saved"
expect eof
EOF
  TEST_T0="$t0" TEST_REF="$ref" expect -f "$script" > "$TEMP/impact.out"
}

run_declare() {
  local scenario="$1" t1="$2" script="$TEMP/declare.exp"
  cat > "$script" <<'EOF'
set timeout 10
spawn bash $env(SCRIPT) declare
  expect "Scenario to recover"
send "$env(TEST_SCENARIO)\r"
if {$env(TEST_SCENARIO) == "S4"} {
  expect "Only S3 is implemented for BB3"
  expect eof
  exit 0
}
expect "Incident declaration T1 UTC ISO-8601"
send "$env(TEST_T1)\r"
expect {
  "T1 cannot be earlier than T0." { expect eof; exit 0 }
  "Declared S3 incident" { expect eof; exit 0 }
}
EOF
  TEST_SCENARIO="$scenario" TEST_T1="$t1" expect -f "$script" > "$TEMP/declare.out"
}

run_impact '' synthetic-monitor-current-utc
# shellcheck source=/dev/null
source "$CONFIG"
[[ "$BB3_T0_AT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\+00:00$ ]]
[[ "$BB3_T0_EVIDENCE_REF" == synthetic-monitor-current-utc ]]

run_impact 2099-01-01T00:00:00Z synthetic-monitor-T0
run_declare S3 ''
grep -q 'T1 cannot be earlier than T0' "$TEMP/declare.out"
records=("$LEDGER"/*/incident.json)
((${#records[@]} == 0))

run_impact 2026-10-20T00:00:00Z synthetic-monitor-T0
run_declare S4 ''
grep -q 'Only S3 is implemented for BB3' "$TEMP/declare.out"
records=("$LEDGER"/*/incident.json)
((${#records[@]} == 0))

run_declare S3 ''
grep -q 'Declared S3 incident' "$TEMP/declare.out"
# shellcheck source=/dev/null
source "$CONFIG"
[[ "$BB3_SCENARIO" == S3 && "$BB3_T0_AT" == 2026-10-20T00:00:00+00:00 && -n "$BB3_T1_AT" && -n "$BB3_DR_ID" ]]
jq -e --arg run "$BB3_DR_ID" --arg t0 "$BB3_T0_AT" --arg t1 "$BB3_T1_AT" \
  '.runId==$run and .scenario=="S3" and .t0At==$t0 and .t1At==$t1 and .t1At >= .t0At and .t1Method=="declaration-time"' \
  "$LEDGER/$BB3_DR_ID/incident.json" >/dev/null
printf '%s\n' 'PASS P1-S01-1 records evidence-based T0 after P0 quarantine; P1-S01-2 reuses the run ID, defaults T1 to UTC now, rejects T1<T0 and S4'