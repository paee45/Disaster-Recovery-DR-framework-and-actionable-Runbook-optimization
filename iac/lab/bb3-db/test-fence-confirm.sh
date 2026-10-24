#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
export SCRIPT="$HERE/fence-confirm.sh"
export TEST_STATE="$TEMP/state" TEST_CALLS="$TEMP/calls"
export TEST_PYTHON="${TEST_PYTHON:-$(command -v python3)}"
export BB3_SANDBOX_CONFIG="$TEMP/sandbox.env" BB3_LEDGER_DIR="$TEMP/ledger"
export TEST_SESSION=y TEST_APPROVE=y TEST_RELEASE=0 TEST_RELEASE_APPROVE=RELEASE-SOURCE-QUARANTINE
export TEST_CONFLICT=0 TEST_DRIFT=none
export TEST_RELEASE_LAG=none
export TEST_CLEANUP=0 TEST_SELECTION=DR-fixture TEST_FAILBACK=1
export TEST_CLEANUP_OWNER=fixture-owner TEST_CLEANUP_EVIDENCE=validation-ticket-123
export TEST_CLEANUP_APPROVE=DELETE-FAILBACK-QUARANTINE TEST_ENI=0
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
mkdir -p "$TEST_STATE" "$BB3_LEDGER_DIR/DR-fixture"
printf '%s\n' 'TF_VAR_aws_profile=lab_sandbox' 'TF_VAR_region=ap-southeast-1' \
  'TF_VAR_account_id=000000000000' 'ENV=uat' > "$BB3_SANDBOX_CONFIG"
RUN_DIR="$BB3_LEDGER_DIR/DR-fixture"
jq -n '{runId:"DR-fixture",status:"complete",account:"000000000000",region:"ap-southeast-1",
  createdAt:"2026-10-21T00:00:00Z",db:"new-primary",replica:"new-replica",
  source_db:"old-primary",source_replica:"old-replica",
  oldHost:"old-primary.example.invalid",oldReplicaHost:"old-replica.example.invalid"}' > "$RUN_DIR/cutover.json"

git() { [[ "$*" == *'check-ignore -q'* ]]; }
python3() { "$TEST_PYTHON" "$@"; }
sleep() { return 0; }
aws() {
  [[ "$1" == --profile && "$2" == lab_sandbox && "$3" == --region &&
    "$4" == ap-southeast-1 && "$5" == --no-cli-pager ]] || return 97
  printf '%s\n' "$*" >> "$TEST_CALLS"
  shift 5
  local service="$1" action="$2" db='' query='' group='' argument
  shift 2
  local -a groups=()
  while [[ $# -gt 0 ]]; do
    argument="$1"; shift
    case "$argument" in
      --db-instance-identifier) db="$1"; shift ;;
      --query) query="$1"; shift ;;
      --group-ids|--group-id)
        while [[ $# -gt 0 && "$1" != --* ]]; do groups+=("$1"); shift; done
        group="${groups[0]}" ;;
      --filters) group="${1##*=}"; shift ;;
      --vpc-security-group-ids)
        while [[ $# -gt 0 && "$1" != --* ]]; do groups+=("$1"); shift; done ;;
      --output|--group-name|--description|--vpc-id|--tag-specifications) shift ;;
      --apply-immediately) ;;
      db-instance-available) ;;
      *) printf 'Unexpected AWS argument: %s\n' "$argument" >&2; return 99 ;;
    esac
  done
  case "$service/$action" in
    sts/get-caller-identity) printf '%s\n' 000000000000 ;;
    rds/describe-db-instances)
      case "$query" in
        '') jq -s '{DBInstances:.}' "$TEST_STATE"/*-primary.json "$TEST_STATE"/*-replica.json ;;
        'DBInstances[0]') jq . "$TEST_STATE/$db.json" ;;
        'DBInstances[0].VpcSecurityGroups')
          if [[ -f "$TEST_STATE/pending-$db" && "$TEST_RELEASE_LAG" == delayed ]]; then
            local remaining
            remaining="$(< "$TEST_STATE/pending-$db")"
            if ((remaining == 0)); then
              jq '.VpcSecurityGroups |= map(.Status="active")' "$TEST_STATE/$db.json" > "$TEST_STATE/db.tmp"
              mv "$TEST_STATE/db.tmp" "$TEST_STATE/$db.json"
              rm "$TEST_STATE/pending-$db"
            else printf '%s\n' "$((remaining - 1))" > "$TEST_STATE/pending-$db"; fi
          fi
          jq '.VpcSecurityGroups' "$TEST_STATE/$db.json" ;;
        'DBInstances[0].VpcSecurityGroups[].VpcSecurityGroupId')
          jq '[.VpcSecurityGroups[].VpcSecurityGroupId]' "$TEST_STATE/$db.json" ;;
        *) return 99 ;;
      esac ;;
    ec2/create-security-group)
      [[ "$TEST_CONFLICT" != 1 ]] || { echo 'InvalidGroup.Duplicate' >&2; return 1; }
      printf '%s\n' sg-acde1234 ;;
    ec2/describe-security-groups)
      if [[ -e "$TEST_STATE/deleted-$group" || ( -e "$TEST_STATE/deleted" && "$group" == sg-acde0000 ) ]]; then
        printf '%s\n' '{"SecurityGroups":[]}'
      elif [[ ${#groups[@]} -gt 1 ]]; then
        printf '%s\n' "${groups[@]}" | jq -R '{GroupId:.,VpcId:"vpc-test"}' | jq -s '{SecurityGroups:.}'
      else
        jq -n --arg sg "$group" --arg drift "$TEST_DRIFT" \
          '{SecurityGroups:[{GroupId:$sg,VpcId:(if $drift=="sg-vpc" then "vpc-other" else "vpc-test" end),
            Tags:[{Key:"dr-run",Value:(if $drift=="tag" then "DR-other" else "DR-fixture" end)},
                  {Key:"dr-role",Value:(if $drift=="role" then "other" else "quarantine" end)}],
            IpPermissions:(if $drift=="ingress" then [{IpProtocol:"-1"}] else [] end)}]}'
      fi ;;
    rds/modify-db-instance)
      local group_json
      group_json="$(printf '%s\n' "${groups[@]}" | jq -R '{VpcSecurityGroupId:.,Status:"active"}' | jq -s .)"
      if [[ "$db" == old-* && "$TEST_RELEASE_LAG" != none ]]; then
        group_json="$(jq 'map(.Status="adding")' <<< "$group_json")"
        printf '%s\n' 2 > "$TEST_STATE/pending-$db"
      fi
      jq --argjson groups "$group_json" '.VpcSecurityGroups=$groups' "$TEST_STATE/$db.json" > "$TEST_STATE/db.tmp"
      mv "$TEST_STATE/db.tmp" "$TEST_STATE/$db.json" ;;
    rds/wait) ;;
    ec2/describe-network-interfaces)
      jq -n --arg eni "$TEST_ENI" '{NetworkInterfaces:(if $eni=="1" then [{NetworkInterfaceId:"eni-fixture"}] else [] end)}' ;;
    ec2/delete-security-group)
      [[ "$group" == sg-acde0000 || "$group" == sg-acde1234 ]] || return 99
      touch "$TEST_STATE/deleted-$group"
      [[ "$group" != sg-acde0000 ]] || touch "$TEST_STATE/deleted" ;;
    *) printf 'Unexpected AWS operation: %s/%s\n' "$service" "$action" >&2; return 99 ;;
  esac
}
export -f git aws python3 sleep
printf '%s\n' \
  'set timeout 15' \
  'set arguments [list]' \
  'if {$env(TEST_FAILBACK)==1} {lappend arguments --failback; if {$env(TEST_SELECTION)!=""} {lappend arguments $env(TEST_SELECTION)}}' \
  'if {$env(TEST_RELEASE)==1} {lappend arguments --release-quarantine}' \
  'if {$env(TEST_CLEANUP)==1} {lappend arguments --cleanup-failback-quarantine}' \
  'spawn bash $env(SCRIPT) {*}$arguments' \
  'expect {' \
  '  "App owner name*:*" {send "fixture-owner\r"; exp_continue}' \
  '  "Apply this quarantine?*:*" {send "$env(TEST_APPROVE)\r"; exp_continue}' \
  '  "Are all app clients and existing DB sessions closed?*:*" {send "$env(TEST_SESSION)\r"; exp_continue}' \
  '  "Type * to continue:*" {send "$env(TEST_RELEASE_APPROVE)\r"; exp_continue}' \
  '  "Post-failback app validation/signoff owner:*" {send "$env(TEST_CLEANUP_OWNER)\r"; exp_continue}' \
  '  "Actual post-failback app validation/signoff evidence reference:*" {send "$env(TEST_CLEANUP_EVIDENCE)\r"; exp_continue}' \
  '  "Type * to confirm*:*" {send "$env(TEST_CLEANUP_APPROVE)\r"; exp_continue}' \
  '  timeout {exit 124}' \
  '  eof {set result [wait]; exit [lindex $result 3]}' \
  '}' > "$TEMP/answer.exp"

reset_databases() {
  local identifier primary replica group
  rm -f "$TEST_STATE/deleted" "$TEST_STATE"/deleted-* "$TEST_STATE"/pending-*
  for identifier in old-primary old-replica new-primary new-replica; do
    primary="${identifier/replica/primary}"
    replica="${identifier/primary/replica}"
    group="sg-$identifier"
    [[ "$identifier" != old-* ]] || group=sg-acde0000
    jq -n --arg id "$identifier" --arg primary "$primary" --arg replica "$replica" --arg sg "$group" \
      '{DBInstanceIdentifier:$id,DBInstanceStatus:"available",DBSubnetGroup:{VpcId:"vpc-test"},
        Endpoint:{Address:($id+".example.invalid")},VpcSecurityGroups:[{VpcSecurityGroupId:$sg,Status:"active"}]} +
       (if $id|endswith("replica") then {ReadReplicaSourceDBInstanceIdentifier:$primary}
        else {ReadReplicaDBInstanceIdentifiers:[$replica]} end)' > "$TEST_STATE/$identifier.json"
  done
  : > "$TEST_CALLS"
}
run_gate() { expect -f "$TEMP/answer.exp" > "$TEMP/output" 2>&1; }
no_mutations() {
  if rg ' (create-security-group|delete-security-group|modify-db-instance|start-db-instance|stop-db-instance) ' "$TEST_CALLS"; then
    echo 'FAIL unexpected mutation' >&2; exit 1
  fi
}
reject_gate() {
  local exit_code=0
  run_gate || exit_code=$?
  if [[ "$exit_code" == 0 || "$exit_code" == 124 || "$exit_code" == 97 || "$exit_code" == 99 ]]; then
    cat "$TEMP/output" >&2
    echo "FAIL unexpected gate result: $exit_code" >&2; exit 1
  fi
  no_mutations
}
edit_json() {
  jq "$2" "$1" > "$TEMP/edit.json"
  mv "$TEMP/edit.json" "$1"
}
reset_databases
jq -n '{runId:"DR-fixture",mode:"cutover",status:"owner-confirmed",account:"000000000000",region:"ap-southeast-1",
  activePrimary:"old-primary",activeReplica:"old-replica",returnPrimary:"new-primary",returnReplica:"new-replica",
  appOwner:"fixture-owner",fenceVerified:true,existingSessionsClosed:true}' > "$RUN_DIR/fence.json"
TEST_APPROVE=n
reject_gate
TEST_APPROVE=y
TEST_CONFLICT=1
if run_gate; then echo 'FAIL adopted an unjournaled existing SG' >&2; exit 1; fi
[[ ! -e "$RUN_DIR/failback-network-fence.json" ]]
[[ "$(grep -c 'rds modify-db-instance' "$TEST_CALLS" || true)" == 0 ]]
TEST_CONFLICT=0
: > "$TEST_CALLS"
run_gate
grep -F 'Reusing saved app owner: fixture-owner' "$TEMP/output" >/dev/null
! grep -F 'App owner name' "$TEMP/output" >/dev/null
[[ "$(jq -r '.appOwner' "$RUN_DIR/failback-fence.json")" == fixture-owner ]]
[[ "$(grep -c 'ec2 create-security-group' "$TEST_CALLS")" == 1 ]]
[[ "$(grep -c 'rds modify-db-instance' "$TEST_CALLS")" == 2 ]]
jq -e '.mode=="failback" and .status=="attached" and
  .previousPrimarySecurityGroups==["sg-new-primary"] and .previousReplicaSecurityGroups==["sg-new-replica"]' \
  "$RUN_DIR/failback-network-fence.json" >/dev/null
cp "$RUN_DIR/failback-network-fence.json" "$TEMP/network-good.json"
cp "$RUN_DIR/failback-fence.json" "$TEMP/fence-good.json"
printf 'PASS approved paired creation and duplicate-name refusal\n'

reset_databases
edit_json "$TEST_STATE/new-primary.json" '.VpcSecurityGroups=[{VpcSecurityGroupId:"sg-acde1234",Status:"active"}]'
edit_json "$RUN_DIR/failback-network-fence.json" '.status="submitted"'
run_gate
[[ "$(grep -c 'rds modify-db-instance' "$TEST_CALLS")" == 1 ]]
grep 'rds modify-db-instance.*--db-instance-identifier new-replica' "$TEST_CALLS" >/dev/null
: > "$TEST_CALLS"
run_gate
no_mutations
TEST_SESSION=n
run_gate
jq -e '.existingSessionsClosed==false' "$RUN_DIR/failback-fence.json" >/dev/null
if python3 "$HERE/secret-endpoints.py" --check-fence "$RUN_DIR/failback-fence.json" \
  DR-fixture 000000000000 ap-southeast-1 new-primary new-replica old-primary old-replica; then
  echo 'FAIL session denial passed endpoint check' >&2; exit 1
fi
TEST_SESSION=y
printf 'PASS partial/attached resume and endpoint rejection after session denial\n'

for defect in mode empty-primary empty-replica vpc; do
  cp "$TEMP/network-good.json" "$RUN_DIR/failback-network-fence.json"
  cp "$TEMP/fence-good.json" "$RUN_DIR/failback-fence.json"
  reset_databases
  case "$defect" in
    mode) edit_json "$RUN_DIR/failback-network-fence.json" '.mode="cutover"' ;;
    empty-primary) edit_json "$RUN_DIR/failback-network-fence.json" '.previousPrimarySecurityGroups=[]' ;;
    empty-replica) edit_json "$RUN_DIR/failback-network-fence.json" '.previousReplicaSecurityGroups=[]' ;;
    vpc) edit_json "$TEST_STATE/new-replica.json" '.DBSubnetGroup.VpcId="vpc-other"' ;;
  esac
  reject_gate
done
printf 'PASS resume rejects mismatched mode, empty original SGs and split VPCs\n'

TEST_RELEASE=1
jq -n '{runId:"DR-fixture",operation:"failback",status:"complete"}' > "$RUN_DIR/failback.json"
jq -n '{runId:"DR-fixture",mode:"cutover",account:"000000000000",region:"ap-southeast-1",status:"attached",
  activePrimary:"old-primary",activeReplica:"old-replica",quarantineSecurityGroup:"sg-acde0000",
  previousPrimarySecurityGroups:["sg-original-primary"],previousReplicaSecurityGroups:["sg-original-replica"]}' \
  > "$RUN_DIR/network-fence.json"
for defect in missing-fence missing-network run account region mode owner status active return sessions verified method \
  network-mode network-status network-sg network-run network-account network-region network-primary network-replica \
  tag role ingress sg-vpc vpc topology extra-replica primary-source primary-status replica-status attachment extra-sg pending \
  shared-sg shared-db; do
  cp "$TEMP/network-good.json" "$RUN_DIR/failback-network-fence.json"
  cp "$TEMP/fence-good.json" "$RUN_DIR/failback-fence.json"
  reset_databases
  for identifier in new-primary new-replica; do
    edit_json "$TEST_STATE/$identifier.json" '.VpcSecurityGroups=[{VpcSecurityGroupId:"sg-acde1234",Status:"active"}]'
  done
  TEST_DRIFT=none
  case "$defect" in
    missing-fence) rm "$RUN_DIR/failback-fence.json" ;;
    missing-network) rm "$RUN_DIR/failback-network-fence.json" ;;
    run|account|region|mode|status|owner|active|return|sessions|verified|method)
      case "$defect" in
        run) filter='.runId="DR-other"' ;; account) filter='.account="111111111111"' ;;
        region) filter='.region="other"' ;; mode) filter='.mode="cutover"' ;;
        status) filter='.status="prepared"' ;; owner) filter='.appOwner=""' ;;
        active) filter='.activeReplica="other"' ;; return) filter='.returnPrimary="other"' ;;
        sessions) filter='.existingSessionsClosed=false' ;; verified) filter='.fenceVerified=false' ;;
        method) filter='.fenceMethod="rds-stopped"' ;;
      esac
      edit_json "$RUN_DIR/failback-fence.json" "$filter" ;;
    network-*)
      case "$defect" in
        network-mode) filter='.mode="cutover"' ;; network-status) filter='.status="submitted"' ;;
        network-sg) filter='.quarantineSecurityGroup="sg-other"' ;; network-run) filter='.runId="DR-other"' ;;
        network-account) filter='.account="111111111111"' ;; network-region) filter='.region="other"' ;;
        network-primary) filter='.activePrimary="other"' ;; network-replica) filter='.activeReplica="other"' ;;
      esac
      edit_json "$RUN_DIR/failback-network-fence.json" "$filter" ;;
    tag|role|ingress|sg-vpc) TEST_DRIFT="$defect" ;;
    vpc) edit_json "$TEST_STATE/new-replica.json" '.DBSubnetGroup.VpcId="vpc-other"' ;;
    topology) edit_json "$TEST_STATE/new-replica.json" '.ReadReplicaSourceDBInstanceIdentifier="other"' ;;
    extra-replica) edit_json "$TEST_STATE/new-primary.json" '.ReadReplicaDBInstanceIdentifiers += ["other"]' ;;
    primary-source) edit_json "$TEST_STATE/new-primary.json" '.ReadReplicaSourceDBInstanceIdentifier="other"' ;;
    primary-status) edit_json "$TEST_STATE/new-primary.json" '.DBInstanceStatus="modifying"' ;;
    replica-status) edit_json "$TEST_STATE/new-replica.json" '.DBInstanceStatus="modifying"' ;;
    attachment) edit_json "$TEST_STATE/new-replica.json" '.VpcSecurityGroups[0].VpcSecurityGroupId="sg-other"' ;;
    extra-sg) edit_json "$TEST_STATE/new-primary.json" '.VpcSecurityGroups += [{VpcSecurityGroupId:"sg-other",Status:"active"}]' ;;
    pending) edit_json "$TEST_STATE/new-primary.json" '.VpcSecurityGroups[0].Status="applying"' ;;
    shared-sg)
      edit_json "$RUN_DIR/failback-network-fence.json" '.quarantineSecurityGroup="sg-acde0000"'
      edit_json "$RUN_DIR/failback-fence.json" '.quarantineSecurityGroup="sg-acde0000"'
      for identifier in new-primary new-replica; do
        edit_json "$TEST_STATE/$identifier.json" '.VpcSecurityGroups[0].VpcSecurityGroupId="sg-acde0000"'
      done ;;
    shared-db)
      edit_json "$RUN_DIR/cutover.json" '.source_db="new-primary"'
      edit_json "$RUN_DIR/failback-fence.json" '.returnPrimary="new-primary"' ;;
  esac
  reject_gate
  if [[ "$defect" == shared-db ]]; then
    edit_json "$RUN_DIR/cutover.json" '.source_db="old-primary"'
  fi
done
printf 'PASS release rejects missing, mismatched and drifted restored fences before all mutations\n'

cp "$TEMP/network-good.json" "$RUN_DIR/failback-network-fence.json"
cp "$TEMP/fence-good.json" "$RUN_DIR/failback-fence.json"
reset_databases
for identifier in new-primary new-replica; do
  edit_json "$TEST_STATE/$identifier.json" '.VpcSecurityGroups=[{VpcSecurityGroupId:"sg-acde1234",Status:"active"}]'
done
TEST_RELEASE_APPROVE=no
reject_gate
TEST_RELEASE_APPROVE=RELEASE-SOURCE-QUARANTINE
run_gate
[[ "$(grep -c 'rds modify-db-instance' "$TEST_CALLS")" == 2 ]]
[[ "$(grep -c 'ec2 delete-security-group' "$TEST_CALLS")" == 1 ]]
if rg 'rds modify-db-instance.*--db-instance-identifier new-' "$TEST_CALLS"; then exit 1; fi
for identifier in old-primary old-replica; do
  jq -e --arg sg "sg-original-${identifier#old-}" '.VpcSecurityGroups==[{VpcSecurityGroupId:$sg,Status:"active"}]' \
    "$TEST_STATE/$identifier.json" >/dev/null
done
for identifier in new-primary new-replica; do
  jq -e '.VpcSecurityGroups==[{VpcSecurityGroupId:"sg-acde1234",Status:"active"}]' "$TEST_STATE/$identifier.json" >/dev/null
done
jq -e '.status=="released"' "$RUN_DIR/network-fence.json" >/dev/null
printf 'PASS source release approval retained; only original SG sets restored; restored pair remains fenced\n'

edit_json "$RUN_DIR/network-fence.json" '.status="attached"'
reset_databases
for identifier in new-primary new-replica; do
  edit_json "$TEST_STATE/$identifier.json" '.VpcSecurityGroups=[{VpcSecurityGroupId:"sg-acde1234",Status:"active"}]'
done
TEST_RELEASE_LAG=delayed
run_gate
grep -F 'SG attachment verification' "$TEMP/output" >/dev/null
jq -e '.status=="released"' "$RUN_DIR/network-fence.json" >/dev/null
[[ "$(grep -c 'rds modify-db-instance' "$TEST_CALLS")" == 2 ]]
printf 'PASS release waits for active saved SG attachments after DB available\n'

edit_json "$RUN_DIR/network-fence.json" '.status="attached"'
reset_databases
for identifier in new-primary new-replica; do
  edit_json "$TEST_STATE/$identifier.json" '.VpcSecurityGroups=[{VpcSecurityGroupId:"sg-acde1234",Status:"active"}]'
done
TEST_RELEASE_LAG=stuck
exit_code=0
run_gate || exit_code=$?
[[ "$exit_code" == 2 ]]
jq -e '.status=="attached"' "$RUN_DIR/network-fence.json" >/dev/null
[[ "$(grep -c 'ec2 delete-security-group' "$TEST_CALLS" || true)" == 0 ]]
grep -F 'source release remains incomplete' "$TEMP/output" >/dev/null
TEST_RELEASE_LAG=none
edit_json "$TEST_STATE/old-primary.json" '.VpcSecurityGroups |= map(.Status="active")'
run_gate
[[ "$(grep -c 'rds modify-db-instance.*--db-instance-identifier old-primary' "$TEST_CALLS")" == 1 ]]
jq -e '.status=="released"' "$RUN_DIR/network-fence.json" >/dev/null
printf 'PASS pending SG timeout retains quarantine and retry skips already restored primary\n'

TEST_RELEASE=0
TEST_CLEANUP=1
jq -n '{runId:"DR-fixture",operation:"failback",status:"complete",account:"000000000000",region:"ap-southeast-1",
  source_db:"new-primary",source_replica:"new-replica",db:"old-primary",replica:"old-replica"}' > "$RUN_DIR/failback.json"
cp "$RUN_DIR/failback.json" "$TEMP/failback-good.json"
cp "$RUN_DIR/network-fence.json" "$TEMP/original-good.json"
write_failback_app_records() {
  jq -n '{runId:"DR-fixture",mode:"failback",status:"owner-confirmed",account:"000000000000",region:"ap-southeast-1",
    appOwner:"fixture-owner",activePrimary:"new-primary",activeReplica:"new-replica",
    returnPrimary:"old-primary",returnReplica:"old-replica",fenceVerified:true,existingSessionsClosed:true}' \
    > "$RUN_DIR/failback-fence.json"
  jq -n '{runId:"DR-fixture",operation:"failback",account:"000000000000",region:"ap-southeast-1",
    mode:"manual",status:"owner-confirmed",appOwner:"fixture-owner",
    evidenceRef:"evidence/bb3-secret-endpoints/DR-fixture/failback-app-deploy.log",
    servicesConverged:true,primaryHost:"old-primary.example.invalid",replicaHost:"old-replica.example.invalid"}' \
    > "$RUN_DIR/failback-app-deploy.json"
  printf '%s\n' 'sanitized deployment fixture' > "$RUN_DIR/failback-app-deploy.log"
  jq -n '{runId:"DR-fixture",operation:"failback",account:"000000000000",region:"ap-southeast-1",
    status:"owner-confirmed",appOwner:"fixture-owner",healthVerified:true,evidenceRef:"health-ref",
    healthCheckAt:"2026-10-22T12:00:00+00:00",primaryHost:"old-primary.example.invalid",
    replicaHost:"old-replica.example.invalid"}' > "$RUN_DIR/failback-app-health.json"
  jq -n '{runId:"DR-fixture",operation:"failback",account:"000000000000",region:"ap-southeast-1",
    status:"owner-confirmed",appOwner:"fixture-owner",businessTransactionVerified:true,
    transactionRef:"txn-ref",transactionAt:"2026-10-22T12:05:00+00:00",
    primaryHost:"old-primary.example.invalid",replicaHost:"old-replica.example.invalid"}' \
    > "$RUN_DIR/failback-app-e2e.json"
}
cp "$RUN_DIR/cutover.json" "$TEMP/cutover-good.json"
for defect in none legacy latest implicit missing-flag exclusive missing-failback failback-run failback-account failback-region \
  failback-status failback-source failback-target missing-release release-run release-account release-region release-mode release-status \
  release-primary release-replica missing-network network-run network-account network-region network-mode network-primary \
  network-replica network-status invalid-sg shared-sg attached eni tag role ingress sg-vpc absent blank-owner blank-evidence \
  generic-evidence declined owner-mismatch missing-app-fence missing-app-deploy missing-app-health missing-app-e2e app-run app-owner app-endpoint app-time app-generic; do
  reset_databases
  rm "$TEST_STATE/new-primary.json" "$TEST_STATE/new-replica.json"
  cp "$TEMP/network-good.json" "$RUN_DIR/failback-network-fence.json"
  cp "$TEMP/original-good.json" "$RUN_DIR/network-fence.json"
  cp "$TEMP/failback-good.json" "$RUN_DIR/failback.json"
  cp "$TEMP/cutover-good.json" "$RUN_DIR/cutover.json"
  write_failback_app_records
  TEST_SELECTION=DR-fixture TEST_FAILBACK=1 TEST_RELEASE=0 TEST_DRIFT=none TEST_ENI=0
  TEST_CLEANUP_OWNER=fixture-owner TEST_CLEANUP_EVIDENCE=validation-ticket-123
  TEST_CLEANUP_APPROVE=DELETE-FAILBACK-QUARANTINE
  case "$defect" in
    legacy) edit_json "$RUN_DIR/failback-network-fence.json" 'del(.vpcId)' ;;
    latest) TEST_SELECTION=latest ;; implicit) TEST_SELECTION='' ;; missing-flag) TEST_FAILBACK=0 ;;
    exclusive) TEST_RELEASE=1 ;; missing-failback) rm "$RUN_DIR/failback.json" ;;
    failback-*)
      case "$defect" in
        failback-run) filter='.runId="DR-other"' ;; failback-account) filter='.account="111111111111"' ;;
        failback-region) filter='.region="other"' ;; failback-status) filter='.status="prepared"' ;;
        failback-source) filter='.source_db="other"' ;; failback-target) filter='.replica="other"' ;;
      esac
      edit_json "$RUN_DIR/failback.json" "$filter" ;;
    missing-release) rm "$RUN_DIR/network-fence.json" ;;
    release-*)
      case "$defect" in
        release-run) filter='.runId="DR-other"' ;; release-account) filter='.account="111111111111"' ;;
        release-region) filter='.region="other"' ;; release-mode) filter='.mode="failback"' ;;
        release-primary) filter='.activePrimary="other"' ;; release-replica) filter='.activeReplica="other"' ;;
        release-status) filter='.status="attached"' ;;
      esac
      edit_json "$RUN_DIR/network-fence.json" "$filter" ;;
    missing-network) rm "$RUN_DIR/failback-network-fence.json" ;;
    network-*)
      case "$defect" in
        network-run) filter='.runId="DR-other"' ;; network-account) filter='.account="111111111111"' ;;
        network-region) filter='.region="other"' ;; network-mode) filter='.mode="cutover"' ;;
        network-primary) filter='.activePrimary="other"' ;; network-replica) filter='.activeReplica="other"' ;;
        network-status) filter='.status="submitted"' ;;
      esac
      edit_json "$RUN_DIR/failback-network-fence.json" "$filter" ;;
    invalid-sg) edit_json "$RUN_DIR/failback-network-fence.json" '.quarantineSecurityGroup="sg-other"' ;;
    shared-sg) edit_json "$RUN_DIR/failback-network-fence.json" '.quarantineSecurityGroup="sg-acde0000"' ;;
    attached) edit_json "$TEST_STATE/old-primary.json" '.VpcSecurityGroups[0].VpcSecurityGroupId="sg-acde1234"' ;;
    eni) TEST_ENI=1 ;; tag|role|ingress|sg-vpc) TEST_DRIFT="$defect" ;;
    absent) touch "$TEST_STATE/deleted-sg-acde1234" ;;
    blank-owner) TEST_CLEANUP_OWNER=' ' ;; blank-evidence) TEST_CLEANUP_EVIDENCE='' ;;
    generic-evidence) TEST_CLEANUP_EVIDENCE=y ;; declined) TEST_CLEANUP_APPROVE=no ;;
    owner-mismatch) TEST_CLEANUP_OWNER=other-owner ;;
    missing-app-fence) rm "$RUN_DIR/failback-fence.json" ;;
    missing-app-deploy) rm "$RUN_DIR/failback-app-deploy.json" ;;
    missing-app-health) rm "$RUN_DIR/failback-app-health.json" ;;
    missing-app-e2e) rm "$RUN_DIR/failback-app-e2e.json" ;;
    app-run) edit_json "$RUN_DIR/failback-app-health.json" '.runId="DR-other"' ;;
    app-owner) edit_json "$RUN_DIR/failback-app-e2e.json" '.appOwner="other-owner"' ;;
    app-endpoint) edit_json "$RUN_DIR/failback-app-deploy.json" '.primaryHost="unexpected.example.invalid"' ;;
    app-time) edit_json "$RUN_DIR/failback-app-health.json" '.healthCheckAt="tomorrow"' ;;
    app-generic) edit_json "$RUN_DIR/failback-app-e2e.json" '.transactionRef="yes"' ;;
  esac
  if [[ "$defect" == none || "$defect" == legacy ]]; then
    run_gate
    [[ "$(grep -c 'ec2 delete-security-group' "$TEST_CALLS")" == 1 ]]
    if rg 'rds (modify|delete|stop|start)-db-instance' "$TEST_CALLS"; then exit 1; fi
    jq -e '.status=="deleted" and .cleanupOwner=="fixture-owner" and .cleanupEvidenceRef=="validation-ticket-123" and
      .postFailbackAppValidated==true and .cleanupApprovedAt!=null and .deletedAt!=null and .vpcId=="vpc-test" and
      .previousPrimarySecurityGroups==["sg-new-primary"] and .previousReplicaSecurityGroups==["sg-new-replica"]' \
      "$RUN_DIR/failback-network-fence.json" >/dev/null
    cp "$RUN_DIR/failback-network-fence.json" "$TEMP/deleted-good.json"
    : > "$TEST_CALLS"
    run_gate
    no_mutations
    cmp "$TEMP/deleted-good.json" "$RUN_DIR/failback-network-fence.json"
    edit_json "$RUN_DIR/failback-network-fence.json" '.cleanupOwner="other-owner"'
    : > "$TEST_CALLS"
    reject_gate
    cp "$TEMP/deleted-good.json" "$RUN_DIR/failback-network-fence.json"
    rm "$RUN_DIR/failback-app-e2e.json"
    : > "$TEST_CALLS"
    reject_gate
    [[ "$(wc -l < "$TEST_CALLS")" == 0 ]]
    write_failback_app_records
    rm "$TEST_STATE/deleted-sg-acde1234"
    : > "$TEST_CALLS"
    reject_gate
    touch "$TEST_STATE/deleted-sg-acde1234"
    TEST_CLEANUP_OWNER='' TEST_CLEANUP_EVIDENCE=''
    edit_json "$RUN_DIR/failback-network-fence.json" '.cleanupEvidenceRef=" y "'
    : > "$TEST_CALLS"
    reject_gate
  else
    reject_gate
  fi
done
printf 'PASS detached/retired failback cleanup, legacy VPC verification, deleted retry and fail-closed cleanup gates\n'