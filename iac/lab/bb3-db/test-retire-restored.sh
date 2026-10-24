#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
audit_fixture="$(jq -cn \
  '{DBSnapshots:[
    {DBSnapshotIdentifier:"owned-manual",DBInstanceIdentifier:"new-primary",DbiResourceId:"db-new-primary",SnapshotType:"manual"},
    {DBSnapshotIdentifier:"owned-system",DBInstanceIdentifier:"new-primary",DbiResourceId:"db-new-primary",SnapshotType:"automated"},
    {DBSnapshotIdentifier:"source",DBInstanceIdentifier:"old-primary",DbiResourceId:"db-old-primary",SnapshotType:"manual"},
    {DBSnapshotIdentifier:"reused-name",DBInstanceIdentifier:"new-primary",DbiResourceId:"db-other",SnapshotType:"manual"}
  ]}' | jq -c --argjson record '{"resourceIds":{"new-primary":"db-new-primary","new-replica":"db-new-replica"}}' \
  --arg primary new-primary --arg replica new-replica --arg run DR-fixture -f "$HERE/retirement-audit.jq")"
jq -e '.manual|length==1' <<< "$audit_fixture" >/dev/null
jq -e '.automated|length==1' <<< "$audit_fixture" >/dev/null
jq -e '.ambiguous|length==1' <<< "$audit_fixture" >/dev/null
printf 'PASS final snapshot audit scopes by immutable resource IDs and excludes original/source snapshots\n'
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
export SCRIPT="$HERE/retire-restored.sh" BB3_LEDGER_DIR="$TEMP/ledger"
export BB3_SANDBOX_CONFIG="$TEMP/sandbox.env" TEST_STATE="$TEMP/state" TEST_CALLS="$TEMP/calls"
TEST_PYTHON="$(command -v python3)"
export TEST_PYTHON TEST_APPROVAL=RETIRE-RESTORED-PAIR TEST_DRIFT=none
export TEST_SNAPSHOT_APPROVAL=''
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
printf '%s\n' 'MOCK TEST ONLY: all AWS calls below use fixture stubs; no live resources are changed.'
PS4='[test] + '
set -x
mkdir -p "$BB3_LEDGER_DIR/DR-fixture" "$TEST_STATE"
printf '%s\n' TF_VAR_aws_profile=lab_sandbox TF_VAR_region=ap-southeast-1 \
  TF_VAR_account_id=000000000000 ENV=uat > "$BB3_SANDBOX_CONFIG"
RUN_DIR="$BB3_LEDGER_DIR/DR-fixture"
jq -n '{runId:"DR-fixture",status:"complete",account:"000000000000",region:"ap-southeast-1",
  createdAt:"2020-01-01T00:00:00Z",db:"new-primary",replica:"new-replica",
  source_db:"old-primary",source_replica:"old-replica",
  secretArn:"arn:aws:secretsmanager:ap-southeast-1:000000000000:secret:fixture",
  oldHost:"old-primary.example.invalid",oldReplicaHost:"old-replica.example.invalid"}' > "$RUN_DIR/cutover.json"
jq -n '{runId:"DR-fixture",operation:"failback",status:"complete",account:"000000000000",region:"ap-southeast-1",
  source_db:"new-primary",source_replica:"new-replica",db:"old-primary",replica:"old-replica"}' > "$RUN_DIR/failback.json"
jq -n '{runId:"DR-fixture",mode:"cutover",status:"released",account:"000000000000",region:"ap-southeast-1",
  activePrimary:"old-primary",activeReplica:"old-replica"}' > "$RUN_DIR/network-fence.json"
jq -n '{runId:"DR-fixture",mode:"failback",status:"attached",account:"000000000000",region:"ap-southeast-1",
  activePrimary:"new-primary",activeReplica:"new-replica",quarantineSecurityGroup:"sg-abcdef"}' > "$RUN_DIR/failback-network-fence.json"
jq -n '{runId:"DR-fixture",mode:"failback",status:"owner-confirmed",account:"000000000000",region:"ap-southeast-1",
  appOwner:"fixture-owner",activePrimary:"new-primary",activeReplica:"new-replica",returnPrimary:"old-primary",
  returnReplica:"old-replica",fenceVerified:true,existingSessionsClosed:true}' > "$RUN_DIR/failback-fence.json"
printf '%s\n' 'Sanitized fixture deployment log' > "$RUN_DIR/failback-app-deploy.log"
python3 "$HERE/secret-endpoints.py" --record-failback-app-deploy "$BB3_LEDGER_DIR" DR-fixture \
  000000000000 ap-southeast-1 fixture-owner evidence/bb3-secret-endpoints/DR-fixture/failback-app-deploy.log >/dev/null
python3 "$HERE/secret-endpoints.py" --record-failback-app-health "$BB3_LEDGER_DIR" DR-fixture \
  000000000000 ap-southeast-1 fixture-owner health-ref 2020-01-01T12:00:00Z >/dev/null
python3 "$HERE/secret-endpoints.py" --record-failback-app-e2e "$BB3_LEDGER_DIR" DR-fixture \
  000000000000 ap-southeast-1 fixture-owner txn-ref 2020-01-01T12:05:00Z >/dev/null
python3 "$HERE/secret-endpoints.py" --record-failback-signoff "$BB3_LEDGER_DIR" DR-fixture \
  000000000000 ap-southeast-1 fixture-owner deployment-ref health-ref transaction-ref SIGN-OFF-FAILBACK >/dev/null

git() { return 0; }
python3() { "$TEST_PYTHON" "$@"; }
aws() {
  [[ "$1" == --profile && "$2" == lab_sandbox && "$3" == --region &&
    "$4" == ap-southeast-1 && "$5" == --no-cli-pager ]] || return 97
  printf '%s\n' "$*" >> "$TEST_CALLS"
  printf '[MOCK AWS] aws' >&2
  printf ' %q' "$@" >&2
  printf '\n' >&2
  shift 5
  local service="$1" action="$2" db='' resource='' waiter='' resource_id='' snapshot_id='' snapshot_type=''
  shift 2
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --db-instance-identifier) db="$2"; shift 2 ;;
      --db-snapshot-identifier) snapshot_id="$2"; shift 2 ;;
      --snapshot-type) snapshot_type="$2"; shift 2 ;;
      --resource-name) resource="$2"; shift 2 ;;
      --dbi-resource-id) resource_id="$2"; shift 2 ;;
      db-snapshot-available|db-snapshot-deleted|db-instance-deleted) waiter="$1"; shift ;;
      *) shift ;;
    esac
  done
  case "$service/$action" in
    sts/get-caller-identity)
      if [[ "$TEST_DRIFT" == account ]]; then echo 111111111111; else echo 000000000000; fi ;;
    rds/describe-db-instances)
      jq -s '{DBInstances:.}' "$TEST_STATE"/*.db ;;
    secretsmanager/get-secret-value)
      jq -cn --arg drift "$TEST_DRIFT" '{DB_HOST:(if $drift=="secret" then "other.invalid" else "old-primary.example.invalid" end),
        DB_REPLICA_HOST:"old-replica.example.invalid",DB_PASSWORD:"synthetic-test-only"}' ;;
    ec2/describe-security-groups)
      if [[ -f "$TEST_STATE/sg-deleted" || "$TEST_DRIFT" == missing-sg ]]; then echo '{"SecurityGroups":[]}'; else
        jq -cn --arg drift "$TEST_DRIFT" '{SecurityGroups:[{GroupId:"sg-abcdef",VpcId:"vpc-fixture",
          IpPermissions:(if $drift=="ingress" then [{IpProtocol:"-1"}] else [] end),
          Tags:[{Key:"dr-run",Value:"DR-fixture"},{Key:"dr-role",Value:"quarantine"}]}]}'
      fi ;;
    rds/list-tags-for-resource)
      if [[ "$resource" == *:snapshot:* ]]; then
        echo '{"TagList":[{"Key":"dr-run","Value":"DR-fixture"},{"Key":"dr-purpose","Value":"retirement-retained"}]}'
      else
        jq -cn --arg drift "$TEST_DRIFT" '{TagList:[{Key:"dr-restore",Value:(if $drift=="tag" then "DR-other" else "DR-fixture" end)}]}'
      fi ;;
    rds/describe-db-snapshots)
      local snapshot_inventory
      snapshot_inventory="$(jq -s '{DBSnapshots:.}' "$TEST_STATE"/*.snapshot)"
      if [[ -n "$snapshot_type" ]]; then
        snapshot_inventory="$(jq --arg type "$snapshot_type" '.DBSnapshots |= map(select(.SnapshotType==$type))' <<< "$snapshot_inventory")"
      fi
      if [[ "$TEST_DRIFT" == extra-identity-change && -z "$snapshot_type" ]]; then
        if [[ -f "$TEST_STATE/snapshot-audited" ]]; then
          snapshot_inventory="$(jq '.DBSnapshots |= map(if .DBSnapshotIdentifier=="extra-manual" then
            .SnapshotCreateTime="2026-10-23T12:00:00Z" else . end)' <<< "$snapshot_inventory")"
        fi
        touch "$TEST_STATE/snapshot-audited"
      fi
      if [[ -f "$TEST_STATE/snapshot" ]]; then
        jq -c --arg drift "$TEST_DRIFT" --arg deleting "$(test -f "$TEST_STATE/snapshot-deleting" && echo true || echo false)" \
          '.DBSnapshots += [{DBSnapshotIdentifier:"bb3-retire-dr-fixture",
          DBInstanceIdentifier:"new-primary",DbiResourceId:"db-new-primary",
          Status:(if $deleting=="true" then "deleting" elif $drift=="snapshot" then "failed" else "available" end),
          Engine:"postgres",SnapshotType:"manual",SnapshotCreateTime:"2026-10-23T00:00:00Z",
          DBSnapshotArn:"arn:aws:rds:ap-southeast-1:000000000000:snapshot:bb3-retire-dr-fixture"}]' <<< "$snapshot_inventory"
      else echo "$snapshot_inventory"; fi ;;
    rds/create-db-snapshot) touch "$TEST_STATE/snapshot"; echo '{}' ;;
    rds/describe-db-instance-automated-backups)
      jq -s --arg drift "$TEST_DRIFT" '{DBInstanceAutomatedBackups:map(
        if $drift=="backup-owner" and .DbiResourceId=="db-new-primary" then
          .DBInstanceAutomatedBackupsArn="arn:aws:rds:ap-southeast-1:111111111111:auto-backup:ab-wrong"
        else . end)}' "$TEST_STATE"/*.backup ;;
    rds/delete-db-instance-automated-backup)
      [[ "$resource_id" == db-new-primary || "$resource_id" == db-new-replica ]] || return 99
      if [[ "$TEST_DRIFT" == backup-pending ]]; then
        jq '.Status="deleting"' "$TEST_STATE/${resource_id#db-}.backup" > "$TEST_STATE/backup-update"
        mv "$TEST_STATE/backup-update" "$TEST_STATE/${resource_id#db-}.backup"
      else rm -f "$TEST_STATE/${resource_id#db-}.backup"; fi
      echo '{}' ;;
    rds/delete-db-snapshot)
      if [[ "$snapshot_id" == bb3-retire-dr-fixture ]]; then
        touch "$TEST_STATE/snapshot-deleting"
      else
        [[ "$snapshot_id" == extra-* && -f "$TEST_STATE/$snapshot_id.snapshot" ]] || return 99
        jq '.Status="deleting"' "$TEST_STATE/$snapshot_id.snapshot" > "$TEST_STATE/update-snapshot"
        mv "$TEST_STATE/update-snapshot" "$TEST_STATE/$snapshot_id.snapshot"
      fi
      echo '{}' ;;
    rds/wait)
      if [[ "$waiter" == db-snapshot-deleted ]]; then
        [[ "$TEST_DRIFT" != snapshot-interrupt ]] || return 1
        if [[ "$snapshot_id" == bb3-retire-dr-fixture ]]; then
          rm -f "$TEST_STATE/snapshot" "$TEST_STATE/snapshot-deleting"
        else
          [[ "$TEST_DRIFT" != extra-interrupt ]] || return 1
          rm -f "$TEST_STATE/$snapshot_id.snapshot"
        fi
      fi
      if [[ "$waiter" == db-instance-deleted ]]; then
        if [[ "$TEST_DRIFT" == interrupt && "$db" == new-replica ]]; then return 1; fi
        rm -f "$TEST_STATE/$db.db"
      fi ;;
    rds/delete-db-instance)
      [[ "$db" == new-primary || "$db" == new-replica ]] || return 99
      jq '.DBInstanceStatus="deleting"' "$TEST_STATE/$db.db" > "$TEST_STATE/update"
      mv "$TEST_STATE/update" "$TEST_STATE/$db.db"
      echo '{}' ;;
    ec2/describe-network-interfaces)
      if [[ "$TEST_DRIFT" == eni ]]; then echo '{"NetworkInterfaces":[{"NetworkInterfaceId":"eni-fixture"}]}';
      else echo '{"NetworkInterfaces":[]}'; fi ;;
    ec2/delete-security-group) touch "$TEST_STATE/sg-deleted" ;;
    resourcegroupstaggingapi/get-resources)
      if [[ "$TEST_DRIFT" == tagged-leftover ]]; then
        echo '{"ResourceTagMappingList":[{"ResourceARN":"arn:aws:ec2:ap-southeast-1:000000000000:security-group/sg-leftover"}]}'
      elif [[ "$TEST_DRIFT" == tag-denied ]]; then return 1
      else echo '{"ResourceTagMappingList":[]}'; fi ;;
    *) printf 'Unexpected AWS call: %s/%s\n' "$service" "$action" >&2; return 99 ;;
  esac
}
export -f git python3 aws

reset_fixture() {
  rm -f "$TEST_STATE"/* "$TEST_CALLS" "$RUN_DIR/retirement.json"
  local identifier
  for identifier in old-primary old-replica new-primary new-replica; do
    jq -n --arg id "$identifier" '{DBInstanceIdentifier:$id,Engine:"postgres",DBInstanceStatus:"available",
      DBInstanceArn:("arn:aws:rds:ap-southeast-1:000000000000:db:"+$id),DbiResourceId:("db-"+$id),
      DeletionProtection:false,Endpoint:{Address:($id+".example.invalid")},
      DBSubnetGroup:{VpcId:"vpc-fixture"},
      ReadReplicaSourceDBInstanceIdentifier:(if ($id|endswith("replica")) then ($id|sub("replica$";"primary")) else null end),
      ReadReplicaDBInstanceIdentifiers:(if ($id|endswith("primary")) then [($id|sub("primary$";"replica"))] else [] end),
      VpcSecurityGroups:[{VpcSecurityGroupId:(if ($id|startswith("new-")) then "sg-abcdef" else "sg-123456" end),Status:"active"}]}' \
      > "$TEST_STATE/$identifier.db"
      jq -n --arg id "$identifier" '{DBInstanceIdentifier:$id,DbiResourceId:("db-"+$id),Status:"retained",
        DBInstanceAutomatedBackupsArn:("arn:aws:rds:ap-southeast-1:000000000000:auto-backup:ab-"+$id)}' \
        > "$TEST_STATE/$identifier.backup"
  done
      touch "$TEST_STATE/source-snapshot" "$TEST_STATE/original-snapshot"
      for identifier in source original; do
        jq -n --arg id "$identifier" '{DBSnapshotIdentifier:$id,DBInstanceIdentifier:"old-primary",
          DbiResourceId:"db-old-primary",Engine:"postgres",SnapshotType:"manual",Status:"available",
          SnapshotCreateTime:"2020-01-01T00:00:00Z",
          DBSnapshotArn:("arn:aws:rds:ap-southeast-1:000000000000:snapshot:"+$id)}' > "$TEST_STATE/$identifier.snapshot"
      done
}
cat > "$TEMP/retirement.exp" <<'EOF'
set timeout 20
log_user 1
log_file -noappend $env(TEST_OUTPUT)
spawn bash $env(SCRIPT) --failback DR-fixture
expect {
  "Retirement app owner*" {send "\r"; exp_continue}
  "Actual retirement/data retention approval reference:*" {send "retention-ticket-1\r"; exp_continue}
  "*to approve the listed snapshot and irreversible resource deletions*" {send "$env(TEST_APPROVAL)\r"; exp_continue}
  "*to approve only this displayed additional snapshot scope*" {send "$env(TEST_SNAPSHOT_APPROVAL)\r"; exp_continue}
  timeout {puts stderr "TIMEOUT waiting for retirement output"; close; exit 96}
  eof {}
}
exit [lindex [wait] 3]
EOF
run_case() {
  local expected="$1" result=0
  printf '\nCASE drift=%s approval=%s expected_exit=%s\n' "$TEST_DRIFT" "${TEST_APPROVAL:-<Enter/cancel>}" "$expected"
  export TEST_OUTPUT="$TEMP/output"
  expect -f "$TEMP/retirement.exp" || result=$?
  printf 'CASE RESULT exit=%s expected=%s\n' "$result" "$expected"
  [[ "$result" == "$expected" ]] || { cat "$TEMP/output" >&2; echo "Expected $expected got $result" >&2; exit 1; }
}
export TEST_DRIFT=none
reset_fixture; run_case 0
jq -e '.status=="complete" and .backupPurgeComplete==true and .backupPolicy=="purge-restored-pair"' \
  "$RUN_DIR/retirement.json" >/dev/null
REPORT="$(find "$RUN_DIR" -maxdepth 1 -name 'retirement-report-*.md' -type f | head -n 1)"
[[ -n "$REPORT" && -s "$REPORT" && -s "$REPORT.sha256" ]]
rg -F 'RETIREMENT COMPLETE (8/8)' "$REPORT" >/dev/null
rg -F 'Untagged unknown resources' "$REPORT" >/dev/null
[[ "$(shasum -a 256 "$REPORT" | awk '{print $1}')" == "$(awk '{print $1}' "$REPORT.sha256")" ]]
grep -F 'Evidence report:' "$TEMP/output" >/dev/null
grep -F 'Report SHA-256:' "$TEMP/output" >/dev/null
for summary in 'RETIREMENT COMPLETE' 'Run: DR-fixture' 'REMOVED - absence verified' \
  'Restored primary: new-primary' 'Restored replica: new-replica' \
  'RETAINED - outside deletion scope' 'Source restore snapshot' 'DR evidence, journals and local evidence packages'; do
  grep -F "$summary" "$TEMP/output" >/dev/null
done
printf 'PASS fresh sign-off permits retirement with explicit approval and no minimum waiting period\n'
export TEST_DRIFT=tagged-leftover
reset_fixture; run_case 2
jq -e '.status=="approved" and .backupPurgeComplete==true and (has("stage8VerifiedAt")|not)' "$RUN_DIR/retirement.json" >/dev/null
export TEST_DRIFT=none
run_case 0
jq -e '.status=="complete" and (.stage8VerifiedAt|type=="string")' "$RUN_DIR/retirement.json" >/dev/null
[[ "$(rg -c 'create-db-snapshot' "$TEST_CALLS")" == 1 ]]
printf 'PASS fresh retirement waits for stage 8 completion and resumes without repeating prior deletions\n'
for TEST_DRIFT in account secret tag ingress missing-sg backup-owner; do
  export TEST_DRIFT
  reset_fixture; run_case 2
  ! rg 'create-db-snapshot|delete-db-instance|delete-security-group' "$TEST_CALLS" >/dev/null
  printf 'PASS %s drift blocks all mutations\n' "$TEST_DRIFT"
done
export TEST_DRIFT=none TEST_APPROVAL=''
for diagnostic in engine cluster protection lifecycle identity vpc quarantine attachment primary-source primary-replicas replica-source replica-dependents shared-quarantine; do
  export TEST_DRIFT=none
  reset_fixture
  target=new-primary
  case "$diagnostic" in
    engine) filter='.Engine="mysql"'; expected='engine failed' ;;
    cluster) filter='.DBClusterIdentifier="cluster-fixture"'; expected='cluster membership failed' ;;
    protection) filter='.DeletionProtection=true'; expected='deletion protection failed' ;;
    lifecycle) filter='.DBInstanceStatus="modifying"'; expected='lifecycle status failed' ;;
    identity) filter='.DbiResourceId="db-recreated"'; expected='resource identity failed' ;;
    vpc) filter='.DBSubnetGroup.VpcId="vpc-other"'; expected='VPC failed' ;;
    quarantine) filter='.VpcSecurityGroups[0].VpcSecurityGroupId="sg-other"'; expected='quarantine security groups failed' ;;
    attachment) filter='.VpcSecurityGroups[0].Status="modifying"'; expected='quarantine attachment status failed' ;;
    primary-source) filter='.ReadReplicaSourceDBInstanceIdentifier="another-primary"'; expected='primary replica source failed' ;;
    primary-replicas) filter='.ReadReplicaDBInstanceIdentifiers=["unexpected-replica"]'; expected='primary replica topology failed' ;;
    replica-source) target=new-replica; filter='.ReadReplicaSourceDBInstanceIdentifier="another-primary"'; expected='replica source failed' ;;
    replica-dependents) target=new-replica; filter='.ReadReplicaDBInstanceIdentifiers=["unexpected-replica"]'; expected='replica dependents failed' ;;
    shared-quarantine)
      cp "$TEST_STATE/new-primary.db" "$TEST_STATE/unrelated.db"
      jq '.DBInstanceIdentifier="unrelated-db"' "$TEST_STATE/unrelated.db" > "$TEST_STATE/diagnostic-update"
      mv "$TEST_STATE/diagnostic-update" "$TEST_STATE/unrelated.db"
      filter='.'; expected='quarantine attached to another DB failed' ;;
  esac
  if [[ "$diagnostic" == identity || "$diagnostic" == vpc ]]; then
    export TEST_DRIFT=interrupt
    TEST_APPROVAL=RETIRE-RESTORED-PAIR run_case 1
    export TEST_DRIFT=none
  fi
  jq "$filter" "$TEST_STATE/$target.db" > "$TEST_STATE/diagnostic-update"
  mv "$TEST_STATE/diagnostic-update" "$TEST_STATE/$target.db"
  : > "$TEST_CALLS"
  run_case 2
  rg -F "$expected" "$TEMP/output" >/dev/null
  rg -F 'Action:' "$TEMP/output" >/dev/null
  rg -F 'Expected' "$TEMP/output" >/dev/null
  rg -F 'observed' "$TEMP/output" >/dev/null
  rg -F 'resume the same run:' "$TEMP/output" >/dev/null
  ! rg 'create-db-snapshot|delete-db-instance|delete-security-group|delete-db-snapshot' "$TEST_CALLS" >/dev/null
  printf 'PASS actionable %s diagnostic blocks further mutations\n' "$diagnostic"
done
reset_fixture; run_case 2
! rg 'create-db-snapshot|delete-db-instance|delete-security-group' "$TEST_CALLS" >/dev/null
printf 'PASS Enter cancels without AWS mutations\n'
export TEST_APPROVAL=RETIRE-RESTORED-PAIR TEST_DRIFT=snapshot
reset_fixture; run_case 2
! rg 'delete-db-instance|delete-security-group' "$TEST_CALLS" >/dev/null
rg 'WAITING: retained snapshot' "$TEMP/output" >/dev/null
printf 'PASS invalid retained snapshot blocks deletion\n'
export TEST_DRIFT=interrupt
reset_fixture; run_case 1
[[ -f "$TEST_STATE/new-primary.db" && ! -f "$TEST_STATE/sg-deleted" ]]
rg 'WAIT INCOMPLETE: DB new-replica deletion' "$TEMP/output" >/dev/null
rg 'Resume: bash iac/lab/bb3-db/retire-restored.sh --failback DR-fixture' "$TEMP/output" >/dev/null
export TEST_DRIFT=none
run_case 0
rg 'WAITER COMPLETE: DB new-primary deletion' "$TEMP/output" >/dev/null
rg 'SG absence verified' "$TEMP/output" >/dev/null
jq -e '.status=="complete" and .replicaDeleteRequested and .primaryDeleteRequested and .sgDeleteRequested' \
  "$RUN_DIR/retirement.json" >/dev/null
[[ -f "$TEST_STATE/old-primary.db" && -f "$TEST_STATE/old-replica.db" && ! -f "$TEST_STATE/snapshot" ]]
[[ -f "$TEST_STATE/old-primary.backup" && -f "$TEST_STATE/old-replica.backup" &&
  ! -f "$TEST_STATE/new-primary.backup" && ! -f "$TEST_STATE/new-replica.backup" &&
  -f "$TEST_STATE/source-snapshot" && -f "$TEST_STATE/original-snapshot" ]]
[[ ! -f "$TEST_STATE/new-primary.db" && ! -f "$TEST_STATE/new-replica.db" ]]
[[ "$(rg -c 'delete-db-instance --db-instance-identifier new-replica' "$TEST_CALLS")" == 1 ]]
printf 'PASS single approval deletes restored DBs/backups and temporary snapshot, preserving originals/source snapshot\n'
before="$(rg -c 'create-db-snapshot|delete-db-instance|delete-security-group|delete-db-snapshot' "$TEST_CALLS")"
REPORT_HASH="$(shasum -a 256 "$REPORT" | awk '{print $1}')"
run_case 0
[[ "$(rg -c 'create-db-snapshot|delete-db-instance|delete-security-group|delete-db-snapshot' "$TEST_CALLS")" == "$before" ]]
[[ "$(shasum -a 256 "$REPORT" | awk '{print $1}')" == "$REPORT_HASH" ]]
grep -F 'Already completed: this was a read-only verification. No changes made.' "$TEMP/output" >/dev/null
NO_COLOR=1 run_case 0
if LC_ALL=C grep -F "$(printf '\033')" "$TEMP/output" >/dev/null; then
  echo 'FAIL NO_COLOR left terminal styling in retirement output' >&2
  exit 1
fi
printf 'PASS completed retry verifies DB/SG/backup absence without mutations\n'
export TEST_DRIFT=eni
reset_fixture; run_case 2
[[ ! -f "$TEST_STATE/sg-deleted" ]]
printf 'PASS ENI attachment blocks quarantine deletion after DB retirement\n'
export TEST_DRIFT=backup-pending
reset_fixture; run_case 2
[[ ! -f "$TEST_STATE/snapshot" ]]
rg 'automated backups still exist' "$TEMP/output" >/dev/null
rm "$TEST_STATE/new-primary.backup" "$TEST_STATE/new-replica.backup"
export TEST_DRIFT=none
run_case 0
[[ "$(rg -c 'create-db-snapshot' "$TEST_CALLS")" == 1 ]]
printf 'PASS pending backup purge resumes without recreating the deleted snapshot\n'
export TEST_DRIFT=snapshot-interrupt
reset_fixture; run_case 1
[[ -f "$TEST_STATE/snapshot" && -f "$TEST_STATE/snapshot-deleting" ]]
rg 'WAIT INCOMPLETE: temporary retirement snapshot' "$TEMP/output" >/dev/null
export TEST_DRIFT=none
run_case 0
[[ ! -f "$TEST_STATE/snapshot" ]]
[[ "$(rg -c 'delete-db-snapshot --db-snapshot-identifier bb3-retire-dr-fixture' "$TEST_CALLS")" == 1 ]]
printf 'PASS interrupted snapshot purge resumes its waiter without duplicate deletion\n'

cp -R "$TEST_STATE" "$TEMP/stage8-state"
cp "$RUN_DIR/retirement.json" "$TEMP/stage8-retirement.json"
reset_stage8() {
  rm -f "$TEST_STATE"/*
  cp "$TEMP/stage8-state/"* "$TEST_STATE/"
  cp "$TEMP/stage8-retirement.json" "$RUN_DIR/retirement.json"
  : > "$TEST_CALLS"
  export TEST_DRIFT=none TEST_SNAPSHOT_APPROVAL=''
}
extra_snapshot() {
  jq -n --arg name "$1" --arg type "$2" --arg resource "${3:-db-new-primary}" \
    '{DBSnapshotIdentifier:$name,DBInstanceIdentifier:"new-primary",DbiResourceId:$resource,
      SnapshotType:$type,Engine:"postgres",Status:"available",SnapshotCreateTime:"2026-10-23T00:00:00Z",
      DBSnapshotArn:("arn:aws:rds:ap-southeast-1:000000000000:snapshot:"+$name)}' > "$TEST_STATE/$1.snapshot"
}

reset_stage8
extra_snapshot extra-system automated
run_case 2
grep -F 'Stage 8 system snapshots remain' "$TEMP/output" >/dev/null
! rg 'delete-' "$TEST_CALLS" >/dev/null
printf 'PASS stage 8 system snapshots block completion without changing active DB retention\n'

reset_stage8
extra_snapshot extra-manual manual db-other
run_case 2
grep -F 'ambiguous snapshot ownership' "$TEMP/output" >/dev/null
! rg 'delete-' "$TEST_CALLS" >/dev/null
printf 'PASS stage 8 refuses ambiguous snapshot identity without mutation\n'

reset_stage8
extra_snapshot extra-backup awsbackup
run_case 2
grep -F 'unsupported snapshot type' "$TEMP/output" >/dev/null
! rg 'delete-' "$TEST_CALLS" >/dev/null
printf 'PASS stage 8 reports unsupported backup-managed recovery data without deletion\n'

reset_stage8
extra_snapshot extra-manual manual
run_case 2
grep -F 'additional snapshot purge not approved' "$TEMP/output" >/dev/null
[[ -f "$TEST_STATE/extra-manual.snapshot" ]]
! rg 'delete-' "$TEST_CALLS" >/dev/null
printf 'PASS stage 8 extra snapshots need separate typed scope approval\n'

export TEST_SNAPSHOT_APPROVAL=PURGE-DR-SNAPSHOTS TEST_DRIFT=extra-identity-change
run_case 2
grep -F 'approved snapshot identity changed' "$TEMP/output" >/dev/null
! rg 'delete-' "$TEST_CALLS" >/dev/null
printf 'PASS stage 8 rechecks snapshot identity after approval before deletion\n'

reset_stage8
extra_snapshot extra-manual manual
export TEST_SNAPSHOT_APPROVAL=PURGE-DR-SNAPSHOTS TEST_DRIFT=extra-interrupt
run_case 1
[[ -f "$TEST_STATE/extra-manual.snapshot" ]]
[[ "$(jq -r '.stage8DeleteRequested["extra-manual"]' "$RUN_DIR/retirement.json")" == true ]]
export TEST_DRIFT=none TEST_SNAPSHOT_APPROVAL=''
run_case 0
[[ ! -f "$TEST_STATE/extra-manual.snapshot" ]]
[[ "$(rg -c 'delete-db-snapshot --db-snapshot-identifier extra-manual' "$TEST_CALLS")" == 1 ]]
[[ -f "$TEST_STATE/source.snapshot" && -f "$TEST_STATE/original.snapshot" ]]
jq -e '.stage8VerifiedAt|type=="string"' "$RUN_DIR/retirement.json" >/dev/null
printf 'PASS stage 8 approved snapshot purge resumes its waiter without repeated deletion and retains originals/source\n'

for audit_drift in tagged-leftover tag-denied; do
  reset_stage8
  export TEST_DRIFT="$audit_drift"
  run_case 2
  if [[ "$audit_drift" == tag-denied ]]; then
    grep -F 'tag:GetResources permission' "$TEMP/output" >/dev/null
  else
    grep -F 'run-tagged resources remain' "$TEMP/output" >/dev/null
  fi
  ! rg 'delete-' "$TEST_CALLS" >/dev/null
done
printf 'PASS stage 8 leftover resources and tag audit permission errors block complete-cleanup claims\n'

reset_stage8
jq -n '{DBInstanceIdentifier:"new-primary",DbiResourceId:"db-new-primary",Status:"retained",
  DBInstanceAutomatedBackupsArn:"arn:aws:rds:ap-southeast-1:000000000000:auto-backup:ab-new-primary",
  DBInstanceAutomatedBackupsReplications:[{DBInstanceAutomatedBackupsArn:"arn:aws:rds:other-region:000000000000:auto-backup:ab-copy"}]}' \
  > "$TEST_STATE/new-primary.backup"
run_case 2
grep -F 'Replicated automated backups exist' "$TEMP/output" >/dev/null
! rg 'delete-' "$TEST_CALLS" >/dev/null
printf 'PASS replicated automated backups require a destination-region plan rather than unscoped deletion\n'