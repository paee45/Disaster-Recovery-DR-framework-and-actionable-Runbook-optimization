#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/fence-request.sh"
TEMP="$(mktemp -d)"
KEEP_TEST_TEMP="${KEEP_TEST_TEMP:-}"
trap 'if [[ "${KEEP_TEST_TEMP:-}" == 1 ]]; then printf "Test fixture retained at %s\\n" "$TEMP"; else rm -rf "$TEMP"; fi' EXIT
CONFIG="$TEMP/sandbox.env"
LEDGER="$TEMP/evidence"
BASELINES="$TEMP/baselines"
CAPTURE_NAME=20261021T000000Z-test

mkdir -p "$LEDGER/DR-test" "$BASELINES/$CAPTURE_NAME/primary" "$BASELINES/$CAPTURE_NAME/replica"
printf '%s\n' \
  'export TF_VAR_aws_profile=lab_sandbox' \
  'export TF_VAR_region=ap-southeast-1' \
  'export TF_VAR_account_id=000000000000' \
  'export ENV=uat' \
  'export BB3_DR_ID=DR-test' \
  'export BB3_T0_AT=2026-10-20T00:00:00Z' \
  'export BB3_T0_EVIDENCE_REF=old-evidence' \
  'export BB3_T1_AT=2026-10-20T00:05:00Z' \
  'export BB3_SCENARIO=S3' \
  'export BB3_SOURCE_PRIMARY_ID=old-primary' \
  'export BB3_SOURCE_REPLICA_ID=old-replica' \
  'export BB3_RESTORE_TARGET_PRIMARY_ID=new-primary' > "$CONFIG"
jq -n '{runId:"DR-test",account:"000000000000",region:"ap-southeast-1",scenario:"S3",status:"declared"}' \
  > "$LEDGER/DR-test/incident.json"
jq -n '{schemaVersion:1,status:"complete",capturedAt:"2026-10-21T00:00:00Z",profile:"lab_sandbox",region:"ap-southeast-1",directory:"20261021T000000Z-test",primary:"primary/baseline.json",replica:"replica/baseline.json"}' \
  > "$BASELINES/$CAPTURE_NAME/capture.json"
cp "$BASELINES/$CAPTURE_NAME/capture.json" "$BASELINES/latest.json"
jq -n '{source:"old-primary",account:"000000000000",region:"ap-southeast-1",instance:{DBSubnetGroup:{VpcId:"vpc-test"},VpcSecurityGroups:[{VpcSecurityGroupId:"sg-original-primary"}]}}' \
  > "$BASELINES/$CAPTURE_NAME/primary/baseline.json"
jq -n '{source:"old-replica",account:"000000000000",region:"ap-southeast-1",instance:{VpcSecurityGroups:[{VpcSecurityGroupId:"sg-original-replica"}]}}' \
  > "$BASELINES/$CAPTURE_NAME/replica/baseline.json"
capture_hash="$(shasum -a 256 "$BASELINES/$CAPTURE_NAME/capture.json" | awk '{print $1}')"
primary_hash="$(shasum -a 256 "$BASELINES/$CAPTURE_NAME/primary/baseline.json" | awk '{print $1}')"
replica_hash="$(shasum -a 256 "$BASELINES/$CAPTURE_NAME/replica/baseline.json" | awk '{print $1}')"
jq -n --arg capture "$capture_hash" --arg primary "$primary_hash" --arg replica "$replica_hash" \
  '{files:[{path:"capture.json",sha256:$capture},{path:"primary/baseline.json",sha256:$primary},{path:"replica/baseline.json",sha256:$replica}]}' \
  > "$BASELINES/$CAPTURE_NAME/manifest.json"

CALLS="$TEMP/aws-calls.log"
ATTACHED="$TEMP/attached.txt"
: > "$CALLS"
: > "$ATTACHED"
mkdir -p "$LEDGER"
git() { return 0; }
aws() {
  local current_run
  current_run="$(awk -F= '$1=="export BB3_DR_ID" {print $2}' "$BB3_SANDBOX_CONFIG")"
  [[ "$1" == --profile && "$3" == --region && "$5" == --no-cli-pager ]] || return 97
  printf '%s\n' "$*" >> "$TEST_CALLS"
  case "$*" in
    *'sts get-caller-identity'*) printf '%s\n' 000000000000 ;;
    *'rds describe-db-instances'*)
      local db='old-primary'
      [[ "$*" != *'--db-instance-identifier old-replica'* ]] || db=old-replica
      if [[ "$*" == *'DBInstances[0].VpcSecurityGroups[].VpcSecurityGroupId'* ]]; then
        if grep -Fxq "$db" "$TEST_ATTACHED"; then
          printf '%s\n' '["sg-acde1234"]'
        elif [[ "$db" == old-primary ]]; then
          printf '%s\n' '["sg-original-primary"]'
        else
          printf '%s\n' '["sg-original-replica"]'
        fi
      elif [[ "$*" == *'DBInstances[0].DBInstanceStatus'* ]]; then
        printf '%s\n' available
      elif [[ "$db" == old-primary ]]; then
        printf '%s\n' '{"DBInstanceIdentifier":"old-primary","DBInstanceStatus":"available","DBSubnetGroup":{"VpcId":"vpc-test"}}'
      else
        printf '%s\n' '{"DBInstanceIdentifier":"old-replica","DBInstanceStatus":"available","ReadReplicaSourceDBInstanceIdentifier":"old-primary","DBSubnetGroup":{"VpcId":"vpc-test"}}'
      fi
      ;;
    *'ec2 create-security-group'*) printf '%s\n' sg-acde1234 ;;
    *'ec2 describe-security-groups'*)
      jq -n --arg run "$current_run" '{SecurityGroups:[{GroupId:"sg-acde1234",VpcId:"vpc-test",Tags:[{Key:"dr-run",Value:$run},{Key:"dr-role",Value:"quarantine"}],IpPermissions:[]}]}' ;;
    *'rds wait db-instance-available'*) printf '%s\n' 'available' ;;
    *'rds modify-db-instance'*)
      if [[ "$*" == *'old-primary'* ]]; then printf '%s\n' old-primary >> "$TEST_ATTACHED"; fi
      if [[ "$*" == *'old-replica'* ]]; then printf '%s\n' old-replica >> "$TEST_ATTACHED"; fi
      printf '%s\n' accepted
      ;;
    *'rds wait '*) printf '%s\n' 'Unexpected waiter in early fence request' >&2; return 98 ;;
    *) printf 'Unexpected AWS call: %s\n' "$*" >&2; return 99 ;;
  esac
}
export -f git aws
export TEST_CALLS="$CALLS" TEST_ATTACHED="$ATTACHED"
export BB3_SANDBOX_CONFIG="$CONFIG" BB3_LEDGER_DIR="$LEDGER" BB3_RESTORE_BASELINE_DIR="$BASELINES"
export BB3_DRILL_ENV_FILE="$CONFIG"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
unset BB3_T0_AT BB3_T0_EVIDENCE_REF BB3_T1_AT BB3_T1_EVIDENCE_REF BB3_SCENARIO

expect_file="$TEMP/answer.exp"
cat > "$expect_file" <<'EOF'
set timeout 20
spawn bash $env(SCRIPT) pre-impact
expect "Keep the app and health monitor active to observe the connection failure."
expect "Create quarantine SG and submit pair changes without waiting?"
send "y\r"
expect "App/monitor/logs evidence reference for observed DB connection failures:"
send "monitor-incident-42\r"
expect "P0 quarantine verified on the source pair"
expect eof
EOF
export SCRIPT
expect -f "$expect_file" > "$TEMP/first-run.out"
source "$CONFIG"
RUN_ID="$BB3_DR_ID"
[[ "$RUN_ID" != DR-test && -n "$RUN_ID" ]]
[[ -f "$LEDGER/DR-test/incident.json" && ! -e "$LEDGER/DR-test/network-fence.json" ]]
jq -e --arg run "$RUN_ID" '.runId==$run and .status=="attached" and .quarantineSecurityGroup=="sg-acde1234" and
  .impactEvidenceRef=="monitor-incident-42" and
  .previousPrimarySecurityGroups==["sg-original-primary"] and
  .previousReplicaSecurityGroups==["sg-original-replica"]' "$LEDGER/$RUN_ID/network-fence.json" >/dev/null
[[ "$(grep -c 'rds modify-db-instance' "$CALLS")" == 2 ]]
[[ "$(grep -c 'rds wait db-instance-available' "$CALLS")" == 2 ]]
grep -F 'old-primary' "$CALLS" >/dev/null
grep -F 'old-replica' "$CALLS" >/dev/null
# shellcheck source=/dev/null
source "$CONFIG"
[[ "${BB3_DR_ID:-}" == "$RUN_ID" && "${BB3_T0_EVIDENCE_REF:-}" == monitor-incident-42 ]]
[[ -z "${BB3_T0_AT:-}" && -z "${BB3_T1_AT:-}" && -z "${BB3_SCENARIO:-}" ]]
[[ ! -e "$LEDGER/$RUN_ID/incident.json" ]]

: > "$CALLS"
expect_file="$TEMP/resume.exp"
cat > "$expect_file" <<'EOF'
set timeout 20
spawn bash $env(SCRIPT) pre-impact
expect "P0 quarantine verified on the source pair"
expect eof
EOF
expect -f "$expect_file" > "$TEMP/resume.out"
[[ "$(grep -c 'rds modify-db-instance' "$CALLS" || true)" == 0 ]]
[[ "$(grep -c 'rds wait db-instance-available' "$CALLS")" == 2 ]]
: > "$CALLS"
jq '.impactEvidenceRef="y"' "$LEDGER/$RUN_ID/network-fence.json" > "$LEDGER/$RUN_ID/network-fence.tmp"
mv "$LEDGER/$RUN_ID/network-fence.tmp" "$LEDGER/$RUN_ID/network-fence.json"
expect_file="$TEMP/evidence-recovery.exp"
cat > "$expect_file" <<'EOF'
set timeout 20
spawn bash $env(SCRIPT) pre-impact
expect "App/monitor/logs evidence reference for observed DB connection failures:"
send "monitor-incident-42-recovered\r"
expect "P0 quarantine verified on the source pair"
expect eof
EOF
expect -f "$expect_file" > "$TEMP/evidence-recovery.out"
[[ "$(grep -c 'rds modify-db-instance' "$CALLS" || true)" == 0 ]]
source "$CONFIG"
[[ "$BB3_T0_EVIDENCE_REF" == monitor-incident-42-recovered ]]
: > "$CALLS"
if bash "$HERE/capture-baseline.sh" > "$TEMP/recapture.out" 2>&1; then
  echo 'FAIL baseline recapture was allowed after quarantine' >&2
  exit 1
fi
grep -F 'original baseline is pinned for this quarantined run' "$TEMP/recapture.out" >/dev/null
[[ ! -s "$CALLS" ]]
echo 'PASS P0-S03 attaches one quarantine SG to both DBs, records app evidence, and resume does not duplicate mutations'