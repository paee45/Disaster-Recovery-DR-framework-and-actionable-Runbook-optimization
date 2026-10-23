#!/usr/bin/env bash
set -euo pipefail

command -v jq >/dev/null || { echo 'jq required.' >&2; exit 2; }
command -v expect >/dev/null || { echo 'expect required.' >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/bb3-app-failback.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
export BB3_LEDGER_DIR="$TEMP/ledger"
export TEST_PYTHON="${TEST_PYTHON:-$(command -v python3)}"
export TEST_AWS_CALLED="$TEMP/aws-called"
export SCRIPT_DEPLOY="$HERE/app-deploy-confirm.sh"
export SCRIPT_RECOVERY="$HERE/app-recovery-confirm.sh"
mkdir -p "$BB3_LEDGER_DIR/DR-fixture"

git() { return 0; }
python3() { exec "$TEST_PYTHON" "$@"; }
aws() { touch "$TEST_AWS_CALLED"; return 99; }
export -f git python3 aws

RUN_DIR="$BB3_LEDGER_DIR/DR-fixture"
jq -n '{runId:"DR-fixture",status:"complete",account:"000000000000",region:"ap-southeast-1",
  createdAt:"2026-10-22T00:00:00Z",db:"new-primary",replica:"new-replica",
  source_db:"old-primary",source_replica:"old-replica",
  oldHost:"old-primary.example.invalid",oldReplicaHost:"old-replica.example.invalid",
  newHost:"new-primary.example.invalid",newReplicaHost:"new-replica.example.invalid"}' > "$RUN_DIR/cutover.json"
jq -n '{runId:"DR-fixture",operation:"failback",status:"complete",account:"000000000000",region:"ap-southeast-1",
  source_db:"new-primary",source_replica:"new-replica",db:"old-primary",replica:"old-replica"}' > "$RUN_DIR/failback.json"
jq -n '{runId:"DR-fixture",mode:"cutover",status:"released",account:"000000000000",region:"ap-southeast-1",
  activePrimary:"old-primary",activeReplica:"old-replica"}' > "$RUN_DIR/network-fence.json"
jq -n '{runId:"DR-fixture",mode:"failback",status:"attached",account:"000000000000",region:"ap-southeast-1",
  activePrimary:"new-primary",activeReplica:"new-replica"}' > "$RUN_DIR/failback-network-fence.json"
jq -n '{runId:"DR-fixture",mode:"failback",status:"owner-confirmed",account:"000000000000",region:"ap-southeast-1",
  appOwner:"owner@example.invalid",activePrimary:"new-primary",activeReplica:"new-replica",
  returnPrimary:"old-primary",returnReplica:"old-replica",fenceVerified:true,existingSessionsClosed:true}' \
  > "$RUN_DIR/failback-fence.json"
jq -n '{runId:"DR-fixture",status:"owner-confirmed",appOwner:"owner@example.invalid",
  primaryHost:"new-primary.example.invalid",replicaHost:"new-replica.example.invalid"}' > "$RUN_DIR/app-deploy.json"
jq -n '{runId:"DR-fixture",status:"owner-confirmed",appOwner:"owner@example.invalid",t8At:"recovery-health"}' \
  > "$RUN_DIR/app-health.json"
jq -n '{runId:"DR-fixture",status:"owner-confirmed",appOwner:"owner@example.invalid",t9At:"recovery-e2e"}' \
  > "$RUN_DIR/app-e2e.json"
cp "$RUN_DIR/app-deploy.json" "$TEMP/recovery-deploy.json"
cp "$RUN_DIR/app-health.json" "$TEMP/recovery-health.json"
cp "$RUN_DIR/app-e2e.json" "$TEMP/recovery-e2e.json"

cat > "$TEMP/expect.exp" <<'EOF'
set timeout 15
expect_before timeout {exit 96}
set command [split $env(TEST_ARGS)]
if {$env(TEST_PHASE) eq "automatic"} {
  spawn bash $env(SCRIPT_DEPLOY) {*}$command
  expect "Select 1 or 2:*" {send "1\r"}
} elseif {$env(TEST_PHASE) eq "deploy" || $env(TEST_PHASE) eq "no-converge" || $env(TEST_PHASE) eq "resume-deploy"} {
  spawn bash $env(SCRIPT_DEPLOY) {*}$command
  expect "Select 1 or 2:*" {send "2\r"}
  expect "App owner name*" {send "\r"}
  if {$env(TEST_PHASE) eq "resume-deploy"} {
    expect "Reusing existing sanitized deployment log*"
    expect "Owner confirms both original endpoints*" {send "y\r"}
  } else {
    expect "Paste the full log*" {send "sanitized deployment log\r\r\r"}
    expect "Owner confirms both original endpoints*" {
      if {$env(TEST_PHASE) eq "deploy"} {send "y\r"} else {send "n\r"}
    }
  }
} elseif {$env(TEST_PHASE) eq "health" || $env(TEST_PHASE) eq "wrong-owner" || $env(TEST_PHASE) eq "missing-evidence"} {
  spawn bash $env(SCRIPT_RECOVERY) connectivity {*}$command
  expect "App owner*" {
    if {$env(TEST_PHASE) eq "wrong-owner"} {send "different-owner\r"} else {send "\r"}
  }
  if {$env(TEST_PHASE) ne "wrong-owner"} {
    expect "Did the app health check succeed*" {send "y\r"}
  }
  if {$env(TEST_PHASE) ne "wrong-owner"} {
  expect "Health-check evidence reference:*" {
    if {$env(TEST_PHASE) eq "missing-evidence"} {send "\r"} else {send "health-ref-1\r"}
  }
    if {$env(TEST_PHASE) ne "missing-evidence"} {
      expect "Actual successful health-check time UTC*" {send "2026-10-22T12:00:00Z\r"}
    }
  }
} elseif {$env(TEST_PHASE) eq "e2e"} {
  spawn bash $env(SCRIPT_RECOVERY) e2e {*}$command
  expect "App owner*" {send "\r"}
  expect "Did a successful business transaction*" {send "y\r"}
  expect "Non-secret transaction/reference ID*" {send "txn-ref-1\r"}
  expect "Actual successful transaction time UTC*" {send "2026-10-22T12:05:00Z\r"}
  expect "Continue to app-owner failback sign-off?*" {send "n\r"}
} elseif {[string match "signoff-*" $env(TEST_PHASE)]} {
  spawn bash $env(SCRIPT_RECOVERY) e2e {*}$command
  expect "Reusing saved failback transaction*"
  if {$env(TEST_PHASE) ne "signoff-existing"} {
    expect "Continue to app-owner failback sign-off?*" {
      if {$env(TEST_PHASE) eq "signoff-default-no"} {send "\r"} else {send "y\r"}
    }
    if {$env(TEST_PHASE) ne "signoff-default-no"} {
      expect "Sign-off app owner*" {
        if {$env(TEST_PHASE) eq "signoff-wrong-owner"} {send "other-owner\r"} else {send "\r"}
      }
      expect "Reusing the displayed saved deployment, health and transaction references for sign-off*"
      expect "*to confirm evidence review and approve failback*" {
        if {$env(TEST_PHASE) eq "signoff-empty-token"} {send "\r"} else {send "SIGN-OFF-FAILBACK\r"}
      }
      if {$env(TEST_PHASE) eq "signoff-success"} {
        expect "Open the separately approved retirement workflow now?*" {send "\r"}
      }
    }
  }
} else {
  exit 98
}
expect eof
set result [wait]
exit [lindex $result 3]
EOF

run_expect() {
  local expected="$1" result=0
  export TEST_ARGS TEST_PHASE
  expect -f "$TEMP/expect.exp" > "$TEMP/output" 2>&1 || result=$?
  [[ "$result" == "$expected" ]] || { cat "$TEMP/output" >&2; echo "Expected exit $expected, got $result" >&2; exit 1; }
}

TEST_ARGS='--failback DR-fixture'; TEST_PHASE=automatic; run_expect 2
rg 'Automatic BB3 application deployment is unavailable' "$TEMP/output" >/dev/null
[[ ! -e "$RUN_DIR/failback-app-deploy.json" && ! -e "$RUN_DIR/failback-app-deploy.log" ]]
printf 'PASS automatic deployment option exits without action or record\n'

TEST_PHASE=deploy; run_expect 0
jq -e '.mode=="manual" and .status=="owner-confirmed" and .appOwner=="owner@example.invalid" and
  .servicesConverged==true and .primaryHost=="old-primary.example.invalid" and
  .replicaHost=="old-replica.example.invalid" and .evidenceRef=="evidence/bb3-secret-endpoints/DR-fixture/failback-app-deploy.log"' \
  "$RUN_DIR/failback-app-deploy.json" >/dev/null
[[ "$(stat -f '%Lp' "$RUN_DIR/failback-app-deploy.log")" == 600 ]]
rg 'synthetic-test-only|DB_PASSWORD' "$RUN_DIR/failback-app-deploy.log" && exit 1 || true
printf 'PASS manual deployment records only saved original endpoints and restrictive sanitized log\n'

TEST_PHASE=wrong-owner; run_expect 2
[[ ! -e "$RUN_DIR/failback-app-health.json" ]]
printf 'PASS health owner mismatch is rejected\n'
TEST_PHASE=missing-evidence; run_expect 2
[[ ! -e "$RUN_DIR/failback-app-health.json" ]]
printf 'PASS missing health evidence is rejected\n'
TEST_PHASE=health; run_expect 0
jq -e '.healthVerified==true and .healthCheckAt=="2026-10-22T12:00:00+00:00" and
  .primaryHost=="old-primary.example.invalid" and .replicaHost=="old-replica.example.invalid"' \
  "$RUN_DIR/failback-app-health.json" >/dev/null
TEST_PHASE=e2e; run_expect 0
jq -e '.businessTransactionVerified==true and .transactionRef=="txn-ref-1" and
  .transactionAt=="2026-10-22T12:05:00+00:00" and .primaryHost=="old-primary.example.invalid" and
  .replicaHost=="old-replica.example.invalid"' "$RUN_DIR/failback-app-e2e.json" >/dev/null
! jq -e 'has("t0At") or has("t8At") or has("t9At") or has("serviceRtoMinutes")' \
  "$RUN_DIR/failback-app-health.json" "$RUN_DIR/failback-app-e2e.json" >/dev/null
cmp "$TEMP/recovery-deploy.json" "$RUN_DIR/app-deploy.json"
cmp "$TEMP/recovery-health.json" "$RUN_DIR/app-health.json"
cmp "$TEMP/recovery-e2e.json" "$RUN_DIR/app-e2e.json"
[[ ! -e "$TEST_AWS_CALLED" ]]
printf 'PASS separate health/E2E records preserve recovery journals and make no AWS calls\n'

cp -R "$RUN_DIR" "$BB3_LEDGER_DIR/DR-no-converge"
rm -f "$BB3_LEDGER_DIR/DR-no-converge"/failback-app-*
find "$BB3_LEDGER_DIR/DR-no-converge" -name '*.json' -type f -exec \
  sh -c 'jq --arg run DR-no-converge "if has(\"runId\") then .runId=\$run else . end" "$1" > "$1.tmp" && mv "$1.tmp" "$1"' _ {} \;
TEST_ARGS='--failback DR-no-converge'; TEST_PHASE=no-converge; run_expect 2
[[ ! -e "$BB3_LEDGER_DIR/DR-no-converge/failback-app-deploy.json" ]]
printf 'PASS deployment without confirmed convergence does not record an attestation\n'

cp -R "$RUN_DIR" "$BB3_LEDGER_DIR/DR-resume"
find "$BB3_LEDGER_DIR/DR-resume" -name '*.json' -type f -exec \
  sh -c 'jq --arg run DR-resume "if has(\"runId\") then .runId=\$run else . end" "$1" > "$1.tmp" && mv "$1.tmp" "$1"' _ {} \;
rm -f "$BB3_LEDGER_DIR/DR-resume/failback-app-deploy.json" \
  "$BB3_LEDGER_DIR/DR-resume/failback-app-health.json" \
  "$BB3_LEDGER_DIR/DR-resume/failback-app-e2e.json"
cp "$RUN_DIR/failback-app-deploy.log" "$BB3_LEDGER_DIR/DR-resume/failback-app-deploy.log"
LOG_HASH="$(shasum -a 256 "$BB3_LEDGER_DIR/DR-resume/failback-app-deploy.log" | awk '{print $1}')"
TEST_ARGS='--failback DR-resume'; TEST_PHASE=resume-deploy; run_expect 0
[[ "$(shasum -a 256 "$BB3_LEDGER_DIR/DR-resume/failback-app-deploy.log" | awk '{print $1}')" == "$LOG_HASH" ]]
jq -e '.status=="owner-confirmed" and .servicesConverged==true' \
  "$BB3_LEDGER_DIR/DR-resume/failback-app-deploy.json" >/dev/null
printf 'PASS retry reuses retained deployment log and records convergence only after renewed owner confirmation\n'

TEST_ARGS='--failback DR-fixture'
cp "$RUN_DIR/failback-app-e2e.json" "$TEMP/saved-transaction.json"
TEST_PHASE=signoff-default-no; run_expect 0
[[ ! -e "$RUN_DIR/failback-signoff.json" ]]
cmp "$TEMP/saved-transaction.json" "$RUN_DIR/failback-app-e2e.json"
printf 'PASS Enter declines sign-off while preserving the saved transaction\n'
TEST_PHASE=signoff-empty-token; run_expect 1
[[ ! -e "$RUN_DIR/failback-signoff.json" ]]
TEST_PHASE=signoff-wrong-owner; run_expect 1
[[ ! -e "$RUN_DIR/failback-signoff.json" ]]
printf 'PASS blank approval and mismatched owner cannot sign off\n'
TEST_PHASE=signoff-success; run_expect 0
jq -e '.status=="signed-off" and .appOwner=="owner@example.invalid" and
  .approval=="SIGN-OFF-FAILBACK" and .evidenceReviewedByOwner==true and .cleanupAuthorized==false and
  .evidence.transaction.transactionRef=="txn-ref-1" and
  .supportingEvidence.deployment=="evidence/bb3-secret-endpoints/DR-fixture/failback-app-deploy.log" and
  .supportingEvidence.health=="health-ref-1" and .supportingEvidence.transaction=="txn-ref-1" and
  (.evidenceHashes|length)==9' \
  "$RUN_DIR/failback-signoff.json" >/dev/null
! rg 'Actual supporting (deployment/convergence|app health|transaction/readback) evidence reference:' "$TEMP/output" >/dev/null
[[ "$(stat -f '%Lp' "$RUN_DIR/failback-signoff.json")" == 600 ]]
cp "$RUN_DIR/failback-signoff.json" "$TEMP/saved-signoff.json"
TEST_PHASE=signoff-existing; run_expect 0
cmp "$TEMP/saved-signoff.json" "$RUN_DIR/failback-signoff.json"
cmp "$TEMP/saved-transaction.json" "$RUN_DIR/failback-app-e2e.json"
printf 'PASS explicit sign-off reuses the transaction, saves restrictive evidence and never overwrites on retry\n'

[[ ! -e "$TEST_AWS_CALLED" ]]
cmp "$TEMP/recovery-deploy.json" "$RUN_DIR/app-deploy.json"
cmp "$TEMP/recovery-health.json" "$RUN_DIR/app-health.json"
cmp "$TEMP/recovery-e2e.json" "$RUN_DIR/app-e2e.json"
printf 'PASS declining retirement makes no AWS calls or recovery journal changes\n'