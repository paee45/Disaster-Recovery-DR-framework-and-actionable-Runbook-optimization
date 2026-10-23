#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077
ulimit -c 0

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
# shellcheck source=bb3-prompt.sh
source "$HERE/bb3-prompt.sh"
die() { echo "Retirement blocked: $*" >&2; exit 2; }
progress() { printf '[%s] [%s/7] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >&2; }
[[ $# == 2 && "$1" == --failback && "$2" =~ ^DR-[A-Za-z0-9_-]{1,120}$ ]] \
  || die 'Usage: retire-restored.sh --failback DR-ID (not latest)'
RUN_ID="$2"
LEDGER="${BB3_LEDGER_DIR:-$ROOT/evidence/bb3-secret-endpoints}"
CONFIG="${BB3_SANDBOX_CONFIG:-$ROOT/iac/sandbox.env}"
[[ -t 0 ]] || die 'Use an interactive terminal.'
[[ -f "$CONFIG" ]] || die 'Missing ignored sandbox config.'
git -C "$ROOT" check-ignore -q "$CONFIG" || die 'Sandbox config must be Git-ignored.'
git -C "$ROOT" check-ignore -q "$LEDGER/$RUN_ID/retirement.json" || die 'Evidence must be Git-ignored.'
# shellcheck source=/dev/null
source "$CONFIG"
unset AWS_DEFAULT_PROFILE TF_VAR_terrakube_token
PROFILE="${TF_VAR_aws_profile:-}"
REGION="${TF_VAR_region:-}"
ACCOUNT="${TF_VAR_account_id:-}"
[[ "$PROFILE" =~ ^(lab_sandbox|pa_aws_sandbox|pa_iam_aws_sandbox)$ &&
   "$REGION" == ap-southeast-1 && "$ACCOUNT" =~ ^[0-9]{12}$ && "${ENV:-}" =~ ^(dev|uat)$ ]] \
  || die 'Only an approved named dev/uat sandbox profile/account/region is allowed.'
[[ -z "${AWS_ACCESS_KEY_ID:-}${AWS_SECRET_ACCESS_KEY:-}${AWS_SESSION_TOKEN:-}" ]] \
  || die 'Unset exported AWS credentials.'
aws_call() { aws --profile "$PROFILE" --region "$REGION" --no-cli-pager "$@"; }
wait_for() {
  local stage="$1" description="$2" exit_code=0
  shift 2
  progress "$stage" "WAITING: $description. AWS polling may take several minutes; no percentage is available."
  bb3_wait "$stage/7: $1" aws --profile "$PROFILE" --region "$REGION" --no-cli-pager rds wait "$@" || exit_code=$?
  if [[ "$exit_code" != 0 ]]; then
    progress "$stage" "WAIT INCOMPLETE: $description. Journal retained; no later stage will run."
    printf 'Resume: bash iac/lab/bb3-db/retire-restored.sh --failback %s\n' "$RUN_ID" >&2
    return "$exit_code"
  fi
  progress "$stage" "WAITER COMPLETE: $description."
}
progress 1 'Checking sandbox identity and immutable failback sign-off.'
[[ "$(aws_call sts get-caller-identity --query Account --output text)" == "$ACCOUNT" ]] \
  || die 'Caller account differs from the approved sandbox.'
CONTEXT="$(python3 "$HERE/secret-endpoints.py" --retirement-context "$LEDGER" "$RUN_ID" "$ACCOUNT" "$REGION")"
RUN_DIR="$LEDGER/$RUN_ID"
JOURNAL="$RUN_DIR/retirement.json"
LOCK="$RUN_DIR/.retirement.lock"
mkdir "$LOCK" || die 'Another retirement may be active; reconcile the lock before retrying.'
trap 'rmdir "$LOCK"' EXIT
PRIMARY="$(jq -er '.restoredPrimary' <<< "$CONTEXT")"
REPLICA="$(jq -er '.restoredReplica' <<< "$CONTEXT")"
QUARANTINE="$(jq -er '.quarantineSecurityGroup' <<< "$CONTEXT")"
SNAPSHOT="$(printf 'bb3-retire-%s' "$RUN_ID" | tr '[:upper:]' '[:lower:]')"
[[ ${#SNAPSHOT} -le 255 ]] || die 'Snapshot identifier too long.'

save_journal() {
  local temporary
  temporary="$(mktemp "$RUN_DIR/.retirement.XXXXXX")"
  jq . <<< "$RECORD" > "$temporary"
  chmod 600 "$temporary"
  mv "$temporary" "$JOURNAL"
}
inventory() {
  INSTANCES="$(aws_call rds describe-db-instances --output json)"
  jq -e '.DBInstances | type=="array"' <<< "$INSTANCES" >/dev/null || die 'Invalid DB inventory.'
  SECURITY_GROUPS="$(aws_call ec2 describe-security-groups --filters "Name=group-id,Values=$QUARANTINE" --output json)"
  jq -e '.SecurityGroups | type=="array"' <<< "$SECURITY_GROUPS" >/dev/null || die 'Invalid SG inventory.'
}
check_originals() {
  jq -e --argjson context "$CONTEXT" --arg sg "$QUARANTINE" '
    [.DBInstances[] | select(.DBInstanceIdentifier==$context.originalPrimary or
      .DBInstanceIdentifier==$context.originalReplica)] as $originals |
    ($originals|length)==2 and all($originals[];
      .Engine=="postgres" and .DBInstanceStatus=="available" and
      all(.VpcSecurityGroups[]; .VpcSecurityGroupId!=$sg)) and
    any($originals[]; .DBInstanceIdentifier==$context.originalPrimary and
      .Endpoint.Address==$context.primaryHost and (.ReadReplicaSourceDBInstanceIdentifier // "")=="") and
    any($originals[]; .DBInstanceIdentifier==$context.originalReplica and
      .Endpoint.Address==$context.replicaHost and .ReadReplicaSourceDBInstanceIdentifier==$context.originalPrimary)
    ' <<< "$INSTANCES" >/dev/null || die 'Original serving pair changed or is not available.'
  local secret_id endpoints
  secret_id="$(jq -er '.secretArn' "$RUN_DIR/cutover.json")"
  endpoints="$(aws_call secretsmanager get-secret-value --secret-id "$secret_id" --version-stage AWSCURRENT \
    --query SecretString --output text | jq -ce '{DB_HOST,DB_REPLICA_HOST}' 2>/dev/null)" \
    || die 'Cannot verify current secret endpoint metadata; response withheld.'
  jq -e --argjson context "$CONTEXT" '.DB_HOST==$context.primaryHost and
    .DB_REPLICA_HOST==$context.replicaHost' <<< "$endpoints" >/dev/null \
    || die 'Current secret no longer points to the signed-off original endpoint pair.'
}
check_restored() {
  jq -e --arg primary "$PRIMARY" --arg replica "$REPLICA" '
    (.vpcId|type=="string" and test("^vpc-[A-Za-z0-9]+$")) and
    all(.resourceIds[$primary],.resourceIds[$replica]; type=="string" and test("^db-[A-Za-z0-9-]+$"))
    ' <<< "$RECORD" >/dev/null || die 'Invalid pinned resource IDs or VPC.'
  jq -e --arg primary "$PRIMARY" --arg replica "$REPLICA" --arg sg "$QUARANTINE" \
    --argjson record "$RECORD" '
    [.DBInstances[] | select(.DBInstanceIdentifier==$primary or .DBInstanceIdentifier==$replica)] as $targets |
    all($targets[];
      .Engine=="postgres" and .DBClusterIdentifier==null and .DeletionProtection==false and
      (.DBInstanceStatus=="available" or .DBInstanceStatus=="deleting") and
      .DbiResourceId==$record.resourceIds[.DBInstanceIdentifier] and
      .DBSubnetGroup.VpcId==$record.vpcId and
      (.VpcSecurityGroups|length)==1 and .VpcSecurityGroups[0].VpcSecurityGroupId==$sg and
      .VpcSecurityGroups[0].Status=="active" and
      (if .DBInstanceIdentifier==$primary then
        (.ReadReplicaSourceDBInstanceIdentifier // "")=="" and
        all(.ReadReplicaDBInstanceIdentifiers[]?; .==$replica)
       else .ReadReplicaSourceDBInstanceIdentifier==$primary and
        (.ReadReplicaDBInstanceIdentifiers // [] | length)==0 end)) and
    all(.DBInstances[] | select(.DBInstanceIdentifier!=$primary and .DBInstanceIdentifier!=$replica);
      all(.VpcSecurityGroups[]?; .VpcSecurityGroupId!=$sg))
    ' <<< "$INSTANCES" >/dev/null || die 'Restored resource identity, topology, protection or quarantine changed.'
  if [[ "$(jq '.SecurityGroups|length' <<< "$SECURITY_GROUPS")" != 0 ]]; then
    jq -e --arg sg "$QUARANTINE" --arg run "$RUN_ID" --arg vpc "$(jq -er '.vpcId' <<< "$RECORD")" '
      (.SecurityGroups|length)==1 and .SecurityGroups[0].GroupId==$sg and
      .SecurityGroups[0].VpcId==$vpc and (.SecurityGroups[0].IpPermissions|length)==0 and
      any(.SecurityGroups[0].Tags[]?; .Key=="dr-run" and .Value==$run) and
      any(.SecurityGroups[0].Tags[]?; .Key=="dr-role" and .Value=="quarantine")
      ' <<< "$SECURITY_GROUPS" >/dev/null || die 'Quarantine SG ownership/VPC/ingress changed.'
  else
    [[ "$(jq -r '.sgDeleteRequested' <<< "$RECORD")" == true ]] \
      || die 'Quarantine disappeared before a recorded deletion; investigate.'
    jq -e --arg primary "$PRIMARY" --arg replica "$REPLICA" \
      'all(.DBInstances[]; .DBInstanceIdentifier!=$primary and .DBInstanceIdentifier!=$replica)' \
      <<< "$INSTANCES" >/dev/null || die 'Quarantine is missing while restored DBs still exist.'
  fi
}
progress 2 'Inspecting DB inventory, original serving endpoints and restored quarantine.'
inventory
check_originals
if [[ -e "$JOURNAL" || -L "$JOURNAL" ]]; then
  progress 2 'Loading saved retirement journal; resource identities must still match.'
  [[ -f "$JOURNAL" && ! -L "$JOURNAL" ]] || die 'Retirement journal must be a regular file.'
  RECORD="$(jq -ce --argjson context "$CONTEXT" --arg snapshot "$SNAPSHOT" '
    select(.context==$context and .snapshot==$snapshot and
      (.status=="prepared" or .status=="approved" or .status=="complete"))' "$JOURNAL")" \
    || die 'Journal does not match this run/sign-off.'
else
  [[ "$(jq --arg primary "$PRIMARY" --arg replica "$REPLICA" \
    '[.DBInstances[] | select(.DBInstanceIdentifier==$primary or .DBInstanceIdentifier==$replica)]|length' \
    <<< "$INSTANCES")" == 2 ]] || die 'Both restored DBs must exist for initial retirement preparation.'
  RECORD="$(jq -cn --argjson context "$CONTEXT" --argjson instances "$INSTANCES" --argjson groups "$SECURITY_GROUPS" \
    --arg snapshot "$SNAPSHOT" '{context:$context,snapshot:$snapshot,status:"prepared",
      vpcId:$groups.SecurityGroups[0].VpcId,
      resourceIds:([$instances.DBInstances[] | select(.DBInstanceIdentifier==$context.restoredPrimary or
        .DBInstanceIdentifier==$context.restoredReplica) | {key:.DBInstanceIdentifier,value:.DbiResourceId}]|from_entries),
      snapshotRequested:false,replicaDeleteRequested:false,primaryDeleteRequested:false,sgDeleteRequested:false}')"
  save_journal
fi
check_restored
for item in "$PRIMARY" "$REPLICA"; do
  arn="$(jq -r --arg id "$item" '.DBInstances[] | select(.DBInstanceIdentifier==$id) | .DBInstanceArn' <<< "$INSTANCES")"
  [[ -n "$arn" ]] || continue
  [[ "$arn" == "arn:aws:rds:$REGION:$ACCOUNT:db:$item" ]] || die 'DB ARN does not match account/region.'
  tags="$(aws_call rds list-tags-for-resource --resource-name "$arn" --output json)"
  jq -e --arg run "$RUN_ID" 'any(.TagList[]; .Key=="dr-restore" and .Value==$run)' <<< "$tags" >/dev/null \
    || die 'Restored DB is missing its exact run ownership tag.'
done

verify_snapshot() {
  local allow_deleting="${1:-false}"
  SNAPSHOTS="$(aws_call rds describe-db-snapshots --snapshot-type manual --output json)"
  jq -e '.DBSnapshots|type=="array"' <<< "$SNAPSHOTS" >/dev/null || die 'Invalid snapshot inventory.'
  SNAPSHOT_JSON="$(jq -c --arg id "$SNAPSHOT" '[.DBSnapshots[] | select(.DBSnapshotIdentifier==$id)]' <<< "$SNAPSHOTS")"
  [[ "$(jq length <<< "$SNAPSHOT_JSON")" == 1 ]] || return 1
  jq -e --arg primary "$PRIMARY" --arg resource "$(jq -er --arg id "$PRIMARY" '.resourceIds[$id]' <<< "$RECORD")" \
    --argjson deleting "$allow_deleting" '.[0].DBInstanceIdentifier==$primary and .[0].DbiResourceId==$resource and
    (.[0].Status=="available" or ($deleting and .[0].Status=="deleting"))' \
    <<< "$SNAPSHOT_JSON" >/dev/null || return 1
  local snapshot_arn snapshot_tags
  snapshot_arn="$(jq -er '.[0].DBSnapshotArn' <<< "$SNAPSHOT_JSON")"
  [[ "$snapshot_arn" == "arn:aws:rds:$REGION:$ACCOUNT:snapshot:$SNAPSHOT" ]] || return 1
  snapshot_tags="$(aws_call rds list-tags-for-resource --resource-name "$snapshot_arn" --output json)"
  jq -e --arg run "$RUN_ID" 'any(.TagList[]; .Key=="dr-run" and .Value==$run) and
    any(.TagList[]; .Key=="dr-purpose" and .Value=="retirement-retained")' <<< "$snapshot_tags" >/dev/null
}
backup_inventory() {
  local identifier="$1" resource="$2"
  BACKUPS="$(aws_call rds describe-db-instance-automated-backups --output json)"
  jq -e '.DBInstanceAutomatedBackups|type=="array"' <<< "$BACKUPS" >/dev/null \
    || die 'Invalid automated backup inventory.'
  BACKUPS="$(jq -c --arg resource "$resource" \
    '{DBInstanceAutomatedBackups:[.DBInstanceAutomatedBackups[] | select(.DbiResourceId==$resource)]}' <<< "$BACKUPS")"
  jq -e --arg id "$identifier" --arg resource "$resource" \
    --arg prefix "arn:aws:rds:$REGION:$ACCOUNT:auto-backup:" '
    .DBInstanceAutomatedBackups | type=="array" and all(.[];
      .DBInstanceIdentifier==$id and .DbiResourceId==$resource and
      (.DBInstanceAutomatedBackupsArn|type=="string" and startswith($prefix)))' \
    <<< "$BACKUPS" >/dev/null || die 'Automated backup identity/account/region mismatch; purge refused.'
}
verify_purged_backups() {
  local identifier resource
  for identifier in "$REPLICA" "$PRIMARY"; do
    resource="$(jq -er --arg id "$identifier" '.resourceIds[$id]' <<< "$RECORD")"
    backup_inventory "$identifier" "$resource"
    [[ "$(jq '.DBInstanceAutomatedBackups|length' <<< "$BACKUPS")" == 0 ]] \
      || die 'Restored automated backups still exist; resume this retirement after AWS finishes deletion.'
  done
  aws_call rds describe-db-snapshots --snapshot-type manual --output json \
    | jq -e --arg id "$SNAPSHOT" '.DBSnapshots|type=="array" and all(.[];.DBSnapshotIdentifier!=$id)' >/dev/null \
    || die 'Temporary retirement snapshot absence not verified.'
}
if [[ "$(jq -r '.status' <<< "$RECORD")" == complete && "$(jq -r '.backupPurgeComplete // false' <<< "$RECORD")" == true ]]; then
  progress 7 'Checking completed retirement: DB, SG and run-owned backup absence (read-only).'
  [[ "$(jq --arg primary "$PRIMARY" --arg replica "$REPLICA" \
    '[.DBInstances[] | select(.DBInstanceIdentifier==$primary or .DBInstanceIdentifier==$replica)]|length' \
    <<< "$INSTANCES")" == 0 && "$(jq '.SecurityGroups|length' <<< "$SECURITY_GROUPS")" == 0 ]] \
    || die 'Completed retirement resources exist again; investigate, do not delete.'
  verify_purged_backups
  echo 'Retirement already complete; DB, SG and run-owned backup absence verified. No changes made.'
  exit 0
fi
progress 3 'Safety checks passed. Review scope and provide separate retirement approval.'
printf 'RETIRE ONLY: replica %s, then primary %s, then quarantine SG %s\n' "$REPLICA" "$PRIMARY" "$QUARANTINE"
printf 'PURGE AFTER DB DELETION: temporary snapshot %s and automated backups for only the restored DB resource IDs.\n' "$SNAPSHOT"
for item in "$REPLICA" "$PRIMARY"; do
  resource="$(jq -er --arg id "$item" '.resourceIds[$id]' <<< "$RECORD")"
  backup_inventory "$item" "$resource"
  printf '  Automated backup scope: DB=%s resource=%s current_records=%s\n' \
    "$item" "$resource" "$(jq '.DBInstanceAutomatedBackups|length' <<< "$BACKUPS")"
done
echo 'RETAIN: original DB pair and its backups, source restore snapshot, other snapshots/SGs/networking/secrets and evidence.'
echo "This approval permanently removes this restored pair's recovery data."
echo 'This is the approved standalone AWS CLI exception, not a Terraform plan. Deletion cannot be undone.'
bb3_prompt_read OWNER "Retirement app owner [$(jq -r '.appOwner' <<< "$CONTEXT")]: "
OWNER="${OWNER:-$(jq -r '.appOwner' <<< "$CONTEXT")}"
[[ "$OWNER" == "$(jq -r '.appOwner' <<< "$CONTEXT")" ]] || die 'Owner differs from the failback sign-off.'
bb3_prompt_read EVIDENCE 'Actual retirement/data retention approval reference: '
[[ -n "${EVIDENCE//[[:space:]]/}" ]] || die 'Retirement approval reference is required.'
bb3_prompt_token_read APPROVAL 'Type ' RETIRE-RESTORED-PAIR \
  ' to approve the listed snapshot and irreversible resource deletions, including backup purge (Enter cancels): '
[[ "$APPROVAL" == RETIRE-RESTORED-PAIR ]] || die 'Not approved; no AWS mutations made.'
RECORD="$(jq --arg owner "$OWNER" --arg evidence "$EVIDENCE" \
  '.status="approved" | .retirementOwner=$owner | .retirementEvidence=$evidence | .approvedAt=(now|todateiso8601) |
    .backupPurgeApproved=true | .backupPolicy="purge-restored-pair"' <<< "$RECORD")"
save_journal
progress 3 'Approval saved. Rechecking live serving endpoints and resource identities before mutations.'
inventory
check_originals
check_restored
if [[ "$(jq -r '.snapshotRequested' <<< "$RECORD")" == false ]]; then
  progress 4 "Checking retained snapshot name and requesting snapshot: $SNAPSHOT."
  aws_call rds describe-db-snapshots --snapshot-type manual --output json \
    | jq -e --arg id "$SNAPSHOT" '.DBSnapshots|type=="array" and all(.[];.DBSnapshotIdentifier!=$id)' >/dev/null \
    || die 'Snapshot ID already occupied or snapshot inventory unavailable.'
  RECORD="$(jq '.snapshotRequested=true' <<< "$RECORD")"; save_journal
  aws_call rds create-db-snapshot --db-instance-identifier "$PRIMARY" --db-snapshot-identifier "$SNAPSHOT" \
    --tags "Key=dr-run,Value=$RUN_ID" 'Key=dr-purpose,Value=retirement-retained' --output json >/dev/null
fi
if [[ "$(jq -r '.snapshotDeleteRequested // false' <<< "$RECORD")" == true ]]; then
  jq -e --arg primary "$PRIMARY" --arg replica "$REPLICA" \
    'all(.DBInstances[]; .DBInstanceIdentifier!=$primary and .DBInstanceIdentifier!=$replica)' \
    <<< "$INSTANCES" >/dev/null || die 'Backup purge was started but restored DBs exist again.'
  progress 4 'Resuming backup purge after verified DB retirement; no safety snapshot will be recreated.'
else
  wait_for 4 "retained snapshot $SNAPSHOT to become available" db-snapshot-available --db-snapshot-identifier "$SNAPSHOT"
  verify_snapshot || die 'Retained snapshot not verified; DB deletion refused.'
  progress 4 'Temporary safety snapshot verified; it will be purged after DB retirement under this approval.'
fi
for item in "$REPLICA" "$PRIMARY"; do
  if [[ "$item" == "$REPLICA" ]]; then stage=5; else stage=6; fi
  progress "$stage" "Rechecking serving endpoints and retirement identity for DB: $item."
  inventory
  check_originals
  check_restored
  if [[ "$item" == "$REPLICA" ]]; then flag=replicaDeleteRequested; else flag=primaryDeleteRequested; fi
  db_status="$(jq -r --arg id "$item" '.DBInstances[] | select(.DBInstanceIdentifier==$id) | .DBInstanceStatus' <<< "$INSTANCES")"
  progress "$stage" "DB $item current status: ${db_status:-absent}."
  if [[ -z "$db_status" ]]; then
    [[ "$(jq -r --arg flag "$flag" '.[$flag]' <<< "$RECORD")" == true ]] \
      || die 'DB disappeared before a recorded retirement request; investigate.'
    continue
  fi
  if [[ "$item" == "$PRIMARY" ]]; then
    jq -e --arg id "$REPLICA" 'all(.DBInstances[]; .DBInstanceIdentifier!=$id)' <<< "$INSTANCES" >/dev/null \
      || die 'Replica must be absent before primary deletion.'
  fi
  if [[ "$db_status" == deleting ]]; then
    [[ "$(jq -r --arg flag "$flag" '.[$flag]' <<< "$RECORD")" == true ]] \
      || die 'Unexpected external DB deletion; investigate.'
  else
    progress "$stage" "Requesting deletion of DB $item; recovery data stays until the final approved backup purge."
    RECORD="$(jq --arg flag "$flag" '.[$flag]=true' <<< "$RECORD")"; save_journal
    aws_call rds delete-db-instance --db-instance-identifier "$item" --skip-final-snapshot \
      --no-delete-automated-backups --output json >/dev/null
  fi
  wait_for "$stage" "DB $item deletion" db-instance-deleted --db-instance-identifier "$item"
done
progress 7 'Verifying both restored DBs are absent and quarantine has no remaining DB/ENI attachments.'
inventory
check_originals
check_restored
jq -e --arg primary "$PRIMARY" --arg replica "$REPLICA" \
  'all(.DBInstances[]; .DBInstanceIdentifier!=$primary and .DBInstanceIdentifier!=$replica)' \
  <<< "$INSTANCES" >/dev/null || die 'DB absence not verified.'
interfaces="$(aws_call ec2 describe-network-interfaces --filters "Name=group-id,Values=$QUARANTINE" --output json)"
jq -e '.NetworkInterfaces|type=="array" and length==0' <<< "$interfaces" >/dev/null \
  || die 'Quarantine still has ENI attachments; rerun after detachment.'
if [[ "$(jq '.SecurityGroups|length' <<< "$SECURITY_GROUPS")" == 0 ]]; then
  [[ "$(jq -r '.sgDeleteRequested' <<< "$RECORD")" == true ]] || die 'SG disappeared outside this retirement.'
else
  progress 7 "Deleting verified detached run-owned quarantine SG: $QUARANTINE."
  RECORD="$(jq '.sgDeleteRequested=true' <<< "$RECORD")"; save_journal
  aws_call ec2 delete-security-group --group-id "$QUARANTINE"
fi
inventory
[[ "$(jq '.SecurityGroups|length' <<< "$SECURITY_GROUPS")" == 0 ]] || die 'SG deletion not verified.'
progress 7 "SG absence verified. Purging only the restored pair's recovery data under the same approval."
for item in "$REPLICA" "$PRIMARY"; do
  resource="$(jq -er --arg id "$item" '.resourceIds[$id]' <<< "$RECORD")"
  backup_inventory "$item" "$resource"
  if [[ "$(jq '.DBInstanceAutomatedBackups|length' <<< "$BACKUPS")" != 0 ]]; then
    if jq -e 'all(.DBInstanceAutomatedBackups[];.Status=="deleting")' <<< "$BACKUPS" >/dev/null; then
      [[ "$(jq -r --arg resource "$resource" '.backupDeleteRequested[$resource] // false' <<< "$RECORD")" == true ]] \
        || die 'Automated backup deletion was not requested by this retirement.'
      progress 7 "Automated backup deletion still pending for $item; absence will be verified before completion."
      continue
    fi
    progress 7 "Deleting restored automated backups for DB $item (resource $resource)."
    RECORD="$(jq --arg resource "$resource" '.backupDeleteRequested[$resource]=true' <<< "$RECORD")"; save_journal
    aws_call rds delete-db-instance-automated-backup --dbi-resource-id "$resource" --output json >/dev/null
  fi
done
if verify_snapshot true; then
  snapshot_status="$(jq -er '.[0].Status' <<< "$SNAPSHOT_JSON")"
  if [[ "$snapshot_status" == deleting ]]; then
    [[ "$(jq -r '.snapshotDeleteRequested // false' <<< "$RECORD")" == true ]] \
      || die 'Snapshot deletion was not requested by this retirement.'
  else
    progress 7 "Deleting verified temporary retirement snapshot: $SNAPSHOT."
    RECORD="$(jq '.snapshotDeleteRequested=true' <<< "$RECORD")"; save_journal
    aws_call rds delete-db-snapshot --db-snapshot-identifier "$SNAPSHOT" --output json >/dev/null
  fi
  wait_for 7 "temporary retirement snapshot $SNAPSHOT deletion" db-snapshot-deleted --db-snapshot-identifier "$SNAPSHOT"
else
  [[ "$(jq length <<< "$SNAPSHOT_JSON")" == 0 && \
    "$(jq -r '.snapshotDeleteRequested // false' <<< "$RECORD")" == true ]] \
    || die 'Temporary snapshot is missing or mismatched before a recorded purge request.'
fi
verify_purged_backups
RECORD="$(jq '.status="complete" | .backupPurgeComplete=true | .completedAt=(now|todateiso8601)' <<< "$RECORD")"; save_journal
echo 'Retirement complete: restored pair, quarantine SG and their scoped recovery data absent. Originals, source snapshot and evidence retained.'