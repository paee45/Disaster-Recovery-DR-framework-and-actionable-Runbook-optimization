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
LAST_RETIREMENT_STAGE=''
progress() {
  local stage="$1" description="$2" title what expected heading='' label='' reset=''
  if [[ "$stage" != "$LAST_RETIREMENT_STAGE" ]]; then
    case "$stage" in
      1)
        title='IDENTITY AND FAILBACK SIGN-OFF'
        what="Verify the configured sandbox account/profile and the explicit run's immutable failback sign-off, then load its retirement scope."
        expected='The caller, app-owner evidence and original/restored DB identities match the signed-off run. No AWS resource is changed; missing or mismatched approval blocks retirement.' ;;
      2)
        title='LIVE SAFETY AND SAVED RESOURCE SCOPE'
        what='Inspect the original serving endpoints, restored DB identities/topology/tags and run-owned quarantine. Create or validate the local retirement journal.'
        expected='The app still points to the original pair; the restored resources match their pinned identities and isolation. Deletion protection and unexpected states remain blockers, not settings to repair automatically.' ;;
      3)
        title='REVIEW AND APPROVE IRREVERSIBLE RETIREMENT'
        what='Show exactly which restored DBs, quarantine SG and recovery backups will be removed. Reuse the saved owner and request a retention-approval reference plus RETIRE-RESTORED-PAIR.'
        expected='Explicit approval is saved before any deletion. Original DBs/backups, the source restore snapshot and evidence stay outside deletion scope. Enter or a wrong token cancels; retry does not bypass this review.' ;;
      4)
        title='TEMPORARY SAFETY SNAPSHOT'
        what='Create or resume the run-owned primary safety snapshot and verify it becomes available before DB deletion. If backup purge already started, verify retirement instead of recreating it.'
        expected='The snapshot identity and scope are verified before continuing. This is temporary recovery data: the approved later purge removes it; it is not a permanently retained backup.' ;;
      5)
        title='RETIRE THE RESTORED REPLICA'
        what='Recheck serving endpoints and restored-resource guards, then request or resume deletion of only the saved restored replica.'
        expected='Replica absence is confirmed before primary deletion. Already-requested deletion resumes its waiter; unexpected disappearance, identity drift or an unsafe lifecycle state stops later actions.' ;;
      6)
        title='RETIRE THE RESTORED PRIMARY'
        what='Recheck serving endpoints, primary identity/quarantine and replica absence, then request or resume deletion of only the saved restored primary.'
        expected="The primary is available, or already deleting after this retirement's recorded request. A modifying primary blocks deletion: wait for the approved change to finish, review its state, then retry this same run. No force-delete or automatic repair occurs." ;;
      7)
        title='DETACHED QUARANTINE AND APPROVED BACKUP PURGE'
        what='Verify both restored DBs and quarantine ENI attachments are absent, remove the detached run-owned SG, then purge only the approved restored-pair automated backups and temporary safety snapshot.'
        expected='Every scoped resource is verified absent before proceeding. Originals and their backups are retained. A completed retry verifies absence without repeating deletions; interrupted purge resumes from the saved journal.' ;;
      8)
        title='FINAL SCOPED AUDIT AND RESULT REPORT'
        what='Audit attributable regional snapshots, quarantine attachments and run-tagged resources. Any additional restored-pair manual snapshot purge requires its separate displayed scope approval.'
        expected='No attributable leftovers remain in the audited account/region before an 8/8 completion report is written. Ambiguous ownership or incomplete inventory blocks success; unrelated, cross-region and unknown untagged resources are not certified or auto-deleted.' ;;
    esac
    if [[ -t 2 && -z "${NO_COLOR+x}" && "${TERM:-dumb}" != dumb ]]; then
      heading=$'\033[1;35m'; label=$'\033[1;36m'; reset=$'\033[0m'
    fi
    printf '\n%s== RETIREMENT %s/8 | %s ==%s\n' "$heading" "$stage" "$title" "$reset" >&2
    printf '%s  What:%s %s\n%s  Expected:%s %s\n' "$label" "$reset" "$what" "$label" "$reset" "$expected" >&2
    LAST_RETIREMENT_STAGE="$stage"
  fi
  printf '[%s] [%s/8] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$stage" "$description" >&2
}
retirement_summary() {
  local highlight='' reset=''
  if [[ -t 1 && -z "${NO_COLOR+x}" && "${TERM:-dumb}" != dumb ]]; then
    highlight=$'\033[1;32m'
    reset=$'\033[0m'
  fi
  printf '\n%s============================================================\n' "$highlight"
  printf 'RETIREMENT COMPLETE\n============================================================%s\n' "$reset"
  printf 'Run: %s\n\n' "$RUN_ID"
  printf '%sREMOVED - absence verified%s\n' "$highlight" "$reset"
  printf '  Restored primary: %s\n  Restored replica: %s\n' "$PRIMARY" "$REPLICA"
  printf '  Run-owned quarantine security group: %s\n' "$QUARANTINE"
  printf '  Automated backups for this restored pair only\n'
  printf '  Temporary retirement snapshot: %s\n\n' "$SNAPSHOT"
  printf '  Other manual snapshots of the restored pair (stage 8 verified)\n\n'
  printf '%sRETAINED - outside deletion scope%s\n' "$highlight" "$reset"
  printf '  Original primary and replica, and their backups\n'
  printf '  Source restore snapshot\n'
  printf '  DR evidence, journals and local evidence packages\n'
  printf '  Unrelated resources and shared sandbox infrastructure\n'
  printf '\nFinal audit scope: this account/region and attributable run resources only.\n'
  if [[ -n "${RETIREMENT_REPORT:-}" && -f "$RETIREMENT_REPORT" ]]; then
    printf 'Evidence report: %s\n' "$RETIREMENT_REPORT"
    printf 'Report SHA-256: %s\n' "$(awk '{print $1}' "$RETIREMENT_REPORT.sha256")"
  fi
  if [[ -n "${1:-}" ]]; then printf '\n%s\n' "$1"; fi
}
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
  bb3_wait "$stage/8: $1" aws --profile "$PROFILE" --region "$REGION" --no-cli-pager rds wait "$@" || exit_code=$?
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
write_retirement_report() {
  local verified_at version temporary report_hash snapshot_ids
  [[ "$(jq -r '.status' <<< "$RECORD")" == complete \
    && -n "$(jq -r '.stage8VerifiedAt // empty' <<< "$RECORD")" ]] \
    || die 'Cannot write a retirement report before stage 8 passes.'
  verified_at="$(jq -er '.stage8VerifiedAt' <<< "$RECORD")"
  version="$(printf '%s' "$verified_at" | tr -c 'A-Za-z0-9T_-' '_')"
  RETIREMENT_REPORT="$RUN_DIR/retirement-report-$version.md"
  temporary="$(mktemp "$RUN_DIR/.retirement-report.XXXXXX")"
  snapshot_ids="$(jq -r '.stage8ApprovedSnapshots[]?.id // empty' <<< "$RECORD")"
  {
    printf '# BB3 Restored Resource Retirement Result\n\n'
    printf -- '- Result: **RETIREMENT COMPLETE (8/8)**\n'
    printf -- '- Run ID: `%s`\n' "$RUN_ID"
    printf -- '- Sandbox account: `%s`\n' "$ACCOUNT"
    printf -- '- Region: `%s`\n' "$REGION"
    printf -- '- Final scoped audit verified at (UTC): `%s`\n\n' "$verified_at"
    printf '## Removed and verified absent\n\n'
    printf -- '- Restored primary `%s` (resource `%s`)\n' "$PRIMARY" "$(jq -er --arg id "$PRIMARY" '.resourceIds[$id]' <<< "$RECORD")"
    printf -- '- Restored replica `%s` (resource `%s`)\n' "$REPLICA" "$(jq -er --arg id "$REPLICA" '.resourceIds[$id]' <<< "$RECORD")"
    printf -- '- Run-owned quarantine security group `%s`\n' "$QUARANTINE"
    printf '%s\n' '- Automated backups for the exact restored DB resource IDs'
    printf -- '- Temporary retirement snapshot `%s`\n' "$SNAPSHOT"
    printf '%s\n' '- Regional manual/system snapshot inventory attributable to the restored DB resource IDs was checked.'
    if [[ -n "$snapshot_ids" ]]; then
      printf '\nAdditional manual snapshots removed under separate stage-8 approval:\n\n'
      while IFS= read -r snapshot_id; do [[ -z "$snapshot_id" ]] || printf -- '- `%s`\n' "$snapshot_id"; done <<< "$snapshot_ids"
    fi
    printf '\n## Retained and outside deletion scope\n\n'
    printf '%s\n' '- Original primary/replica and their backups' '- Source restore snapshot' \
      '- DR journals, checksums and evidence packages' '- Unrelated/shared resources and cross-region copies'
    printf '\n## Audit limits\n\n'
    printf '%s\n' '- Pinned restored DB resource IDs, regional snapshots, quarantine attachments and run-tagged resources were checked.' \
      '- Untagged unknown resources and cross-region copies are outside this report.' \
      '- Retained resources outside the deletion scope were not independently audited.'
  } > "$temporary"
  chmod 600 "$temporary"
  if [[ -e "$RETIREMENT_REPORT" || -L "$RETIREMENT_REPORT" ]]; then
    [[ -f "$RETIREMENT_REPORT" && ! -L "$RETIREMENT_REPORT" ]] \
      || die 'Existing retirement report is not a regular file.'
    cmp -s "$temporary" "$RETIREMENT_REPORT" \
      || die 'Existing retirement report differs; immutable report was not overwritten.'
    rm -f "$temporary"
  else
    ln "$temporary" "$RETIREMENT_REPORT" || die 'Could not create immutable retirement report.'
    rm -f "$temporary"
  fi
  report_hash="$(if command -v sha256sum >/dev/null 2>&1; then sha256sum "$RETIREMENT_REPORT"; else shasum -a 256 "$RETIREMENT_REPORT"; fi | awk '{print $1}')"
  if [[ -e "$RETIREMENT_REPORT.sha256" || -L "$RETIREMENT_REPORT.sha256" ]]; then
    [[ -f "$RETIREMENT_REPORT.sha256" && ! -L "$RETIREMENT_REPORT.sha256" \
      && "$(awk '{print $1}' "$RETIREMENT_REPORT.sha256")" == "$report_hash" ]] \
      || die 'Retirement report checksum mismatch; no report was overwritten.'
  else
    temporary="$(mktemp "$RUN_DIR/.retirement-report-hash.XXXXXX")"
    printf '%s  %s\n' "$report_hash" "${RETIREMENT_REPORT##*/}" > "$temporary"
    chmod 600 "$temporary"
    ln "$temporary" "$RETIREMENT_REPORT.sha256" || die 'Could not create retirement report checksum.'
    rm -f "$temporary"
  fi
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
restored_failure_details() {
  jq -r --arg primary "$PRIMARY" --arg replica "$REPLICA" --arg sg "$QUARANTINE" \
    --argjson record "$RECORD" '
    def problem($db; $field; $expected; $actual; $action):
      "  DB \($db.DBInstanceIdentifier): \($field) failed. Expected \($expected|tojson); observed \($actual|tojson).\n    Action: \($action)";
    .DBInstances[] as $db |
    if ($db.DBInstanceIdentifier==$primary or $db.DBInstanceIdentifier==$replica) then
      (if $db.Engine!="postgres" then problem($db; "engine"; "postgres"; $db.Engine;
        "Stop and verify the selected run and live resource. Do not repin the journal to another DB.") else empty end),
      (if $db.DBClusterIdentifier!=null then problem($db; "cluster membership"; null; $db.DBClusterIdentifier;
        "Stop: this workflow supports standalone RDS instances, not cluster members. Obtain an owner-reviewed retirement plan.") else empty end),
      (if $db.DeletionProtection!=false then problem($db; "deletion protection"; false; $db.DeletionProtection;
        "Keep protection in place. Ask the resource owner to review the change; this script never disables protection.") else empty end),
      (if ($db.DBInstanceStatus!="available" and $db.DBInstanceStatus!="deleting") then
        problem($db; "lifecycle status"; ["available","deleting"]; $db.DBInstanceStatus;
          "If an approved RDS change is still running, wait for it to finish and recheck. If the state persists or is unexpected, investigate before retrying.") else empty end),
      (if $db.DbiResourceId!=$record.resourceIds[$db.DBInstanceIdentifier] then
        problem($db; "resource identity"; $record.resourceIds[$db.DBInstanceIdentifier]; $db.DbiResourceId;
          "Stop: the identifier may refer to a recreated/different DB. Verify run ownership with the owner; do not edit pinned IDs to force deletion.") else empty end),
      (if $db.DBSubnetGroup.VpcId!=$record.vpcId then problem($db; "VPC"; $record.vpcId; $db.DBSubnetGroup.VpcId;
        "Stop and reconcile the run, account and network scope with the owner. Do not change the saved VPC to bypass this check.") else empty end),
      (if (($db.VpcSecurityGroups|length)!=1 or $db.VpcSecurityGroups[0].VpcSecurityGroupId!=$sg) then
        problem($db; "quarantine security groups"; [$sg]; [$db.VpcSecurityGroups[]?.VpcSecurityGroupId];
          "Stop retirement. Review the failback fence and all DB consumers; restore verified isolation only through the approved fencing procedure. Do not detach the quarantine as a workaround.") else empty end),
      (if $db.VpcSecurityGroups[0].Status!="active" then
        problem($db; "quarantine attachment status"; "active"; $db.VpcSecurityGroups[0].Status;
          "Wait for an approved SG attachment change to become active, then recheck. Unexpected or stuck attachment state requires owner investigation.") else empty end),
      (if $db.DBInstanceIdentifier==$primary then
        (if ($db.ReadReplicaSourceDBInstanceIdentifier // "")!="" then
          problem($db; "primary replica source"; ""; $db.ReadReplicaSourceDBInstanceIdentifier;
            "Stop: the saved primary is now a replica. Review topology and run ownership; do not promote or rewire DBs to force retirement.") else empty end),
        (if any($db.ReadReplicaDBInstanceIdentifiers[]?; .!=$replica) then
          problem($db; "primary replica topology"; ["none or only the saved restored replica"]; $db.ReadReplicaDBInstanceIdentifiers;
            "Stop: an unexpected replica depends on this primary. Identify its owner and obtain an approved plan; never delete that replica automatically.") else empty end)
       else
        (if $db.ReadReplicaSourceDBInstanceIdentifier!=$primary then
          problem($db; "replica source"; $primary; $db.ReadReplicaSourceDBInstanceIdentifier;
            "Stop and reconcile the changed replica association with the owner. Do not rewire or delete a different pair.") else empty end),
        (if ($db.ReadReplicaDBInstanceIdentifiers // [] | length)!=0 then
          problem($db; "replica dependents"; []; $db.ReadReplicaDBInstanceIdentifiers;
            "Stop: the restored replica has dependents. Obtain an owner-reviewed plan; do not cascade-delete other resources.") else empty end)
       end)
    elif any($db.VpcSecurityGroups[]?; .VpcSecurityGroupId==$sg) then
      problem($db; "quarantine attached to another DB"; "no unrelated attachments"; $sg;
        "Stop: quarantine is shared with a DB outside this run. Investigate ownership; do not detach or delete the shared SG.")
    else empty end' <<< "$INSTANCES" >&2 \
    || echo '  Detailed checks could not be evaluated; inspect the read-only DB inventory before retrying.' >&2
  echo 'No later retirement action will run. Existing journal and any earlier completed deletions are retained.' >&2
  printf 'After owner review and verification, resume the same run: bash iac/lab/bb3-db/retire-restored.sh --failback %s\n' "$RUN_ID" >&2
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
    ' <<< "$INSTANCES" >/dev/null || {
      restored_failure_details
      die 'Restored resource checks failed; see the specific failed checks and actions above. No automatic repair was attempted.'
    }
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
  jq -e 'all(.DBInstanceAutomatedBackups[]; (.DBInstanceAutomatedBackupsReplications // [] | length)==0)' \
    <<< "$BACKUPS" >/dev/null \
    || die 'Replicated automated backups exist. Obtain an owner-approved destination-region check/cleanup; this regional workflow cannot certify their absence.'
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

stage_eight_snapshots() {
  local snapshots managed
  snapshots="$(aws_call rds describe-db-snapshots --output json)"
  managed="$(aws_call rds describe-db-snapshots --snapshot-type awsbackup --output json)" \
    || die 'Stage 8 cannot inspect AWS Backup-managed DB snapshots. Review permissions/API support; no complete-cleanup claim can be made.'
  snapshots="$(jq -ce --argjson managed "$managed" '
    if (.DBSnapshots|type)=="array" and ($managed.DBSnapshots|type)=="array" then
      {DBSnapshots:((.DBSnapshots+$managed.DBSnapshots)|unique_by([.DBSnapshotArn,.DBSnapshotIdentifier]))}
    else error("Invalid managed snapshot inventory") end' <<< "$snapshots")" \
    || die 'Stage 8 combined snapshot inventory is invalid.'
  FINAL_SNAPSHOTS="$(jq -ce --arg primary "$PRIMARY" --arg replica "$REPLICA" --arg run "$RUN_ID" \
    --argjson record "$RECORD" -f "$HERE/retirement-audit.jq" <<< "$snapshots")" \
    || die 'Stage 8 snapshot inventory could not be classified; no final cleanup claim can be made.'
  if [[ "$(jq '.ambiguous|length' <<< "$FINAL_SNAPSHOTS")" != 0 ]]; then
    jq -r '.ambiguous[] | "Unresolved snapshot: \(.DBSnapshotIdentifier), DB=\(.DBInstanceIdentifier), resource=\(.DbiResourceId // "missing")"' \
      <<< "$FINAL_SNAPSHOTS" >&2
    die 'Stage 8 found ambiguous snapshot ownership. Review with the owner; no name-only or tag-only deletion is allowed.'
  fi
  [[ "$(jq '.unsupported|length' <<< "$FINAL_SNAPSHOTS")" == 0 ]] \
    || die 'Stage 8 found an unsupported snapshot type for the restored pair (possibly AWS Backup-managed). Use an owner-reviewed cleanup procedure; do not delete it by guesswork.'
  if [[ "$(jq '.automated|length' <<< "$FINAL_SNAPSHOTS")" != 0 ]]; then
    jq -r '.automated[] | "System snapshot still visible: \(.DBSnapshotIdentifier), status=\(.Status)"' <<< "$FINAL_SNAPSHOTS" >&2
    die 'Stage 8 system snapshots remain. Recheck retained automated backup deletion/propagation and rerun this same retirement. Never delete system snapshots individually or reduce retention on the original active DBs.'
  fi
  jq -e --arg primary "$PRIMARY" --arg replica "$REPLICA" --argjson record "$RECORD" \
    --arg prefix "arn:aws:rds:$REGION:$ACCOUNT:snapshot:" '
    all(.manual[]; .Engine=="postgres" and .SnapshotType=="manual" and
      (.DBInstanceIdentifier==$primary or .DBInstanceIdentifier==$replica) and
      .DbiResourceId==$record.resourceIds[.DBInstanceIdentifier] and
      (.DBSnapshotIdentifier|type=="string" and test("^[A-Za-z][A-Za-z0-9-]{0,254}$")) and
      .DBSnapshotArn==($prefix+.DBSnapshotIdentifier) and
      (.SnapshotCreateTime|type=="string" and length>0) and
      (.Status=="available" or .Status=="deleting"))' <<< "$FINAL_SNAPSHOTS" >/dev/null \
    || die 'Stage 8 manual snapshot identity, account/region, creation time or status is unsafe; no purge attempted.'
}

stage_eight_scope() {
  jq -c '[.manual[] | {id:.DBSnapshotIdentifier,arn:.DBSnapshotArn,db:.DBInstanceIdentifier,
    resource:.DbiResourceId,created:.SnapshotCreateTime}] | sort_by(.id)' <<< "$FINAL_SNAPSHOTS"
}

stage_eight_cleanup() {
  local scope approved needs_approval approval='' selected current snapshot_id snapshot_status
  local tagged key mappings interfaces resource source_quarantine source_groups
  FINAL_CLEANUP_CHANGED=false
  progress 8 'Final scoped audit: restored DBs, retained/system backups, manual snapshots, quarantine ENIs and tagged run resources.'
  inventory
  check_originals
  [[ "$(jq '.SecurityGroups|length' <<< "$SECURITY_GROUPS")" == 0 ]] \
    || die 'Stage 8 restored quarantine SG still exists; inspect retirement progress before retrying.'
  jq -e --arg primary "$PRIMARY" --arg replica "$REPLICA" '
    all(.DBInstances[]; .DBInstanceIdentifier!=$primary and .DBInstanceIdentifier!=$replica)' \
    <<< "$INSTANCES" >/dev/null || die 'Stage 8 restored DBs still exist; no snapshot purge is allowed.'
  verify_purged_backups
  stage_eight_snapshots
  scope="$(stage_eight_scope)"
  approved="$(jq -c '.stage8ApprovedSnapshots // []' <<< "$RECORD")"
  needs_approval="$(jq -n --argjson scope "$scope" --argjson approved "$approved" \
    'any($scope[]; . as $snapshot | ($approved|index($snapshot))==null)')"
  if [[ "$needs_approval" == true ]]; then
    echo 'STAGE 8 ADDITIONAL SNAPSHOT PURGE - irreversible, not covered by the earlier temporary-snapshot approval.' >&2
    jq -r '.[] | "  Snapshot: \(.id) | DB: \(.db) | resource: \(.resource) | created: \(.created)"' <<< "$scope" >&2
    echo 'Only these manual snapshots of the pinned restored DB resources are selected. Originals/source snapshots and evidence are not selected.' >&2
    bb3_prompt_token_read approval 'Type ' PURGE-DR-SNAPSHOTS ' to approve only this displayed additional snapshot scope (Enter cancels): '
    [[ "$approval" == PURGE-DR-SNAPSHOTS ]] \
      || die 'Stage 8 additional snapshot purge not approved. Earlier retirement is retained; no additional snapshot deletion was requested.'
    RECORD="$(jq --argjson scope "$scope" '.stage8ApprovedSnapshots=((.stage8ApprovedSnapshots // [])+$scope|unique) |
      .stage8ApprovedAt=(now|todateiso8601)' <<< "$RECORD")"
    save_journal
    FINAL_CLEANUP_CHANGED=true
  fi
  while IFS= read -r selected; do
    snapshot_id="$(jq -er '.id' <<< "$selected")"
    stage_eight_snapshots
    current="$(stage_eight_scope | jq -c --arg id "$snapshot_id" '.[] | select(.id==$id)')"
    [[ "$current" == "$selected" ]] \
      || die 'Stage 8 approved snapshot identity changed or disappeared; investigate rather than repinning approval.'
    approved="$(jq -c '.stage8ApprovedSnapshots // []' <<< "$RECORD")"
    jq -e --argjson selected "$selected" 'index($selected)!=null' <<< "$approved" >/dev/null \
      || die 'Stage 8 snapshot has no matching saved scope approval.'
    snapshot_status="$(jq -er --arg id "$snapshot_id" '.manual[] | select(.DBSnapshotIdentifier==$id) | .Status' <<< "$FINAL_SNAPSHOTS")"
    if [[ "$snapshot_status" == deleting ]]; then
      [[ "$(jq -r --arg id "$snapshot_id" '.stage8DeleteRequested[$id] // false' <<< "$RECORD")" == true ]] \
        || die 'Stage 8 snapshot deletion was not requested by this retirement; investigate.'
    else
      RECORD="$(jq --arg id "$snapshot_id" '.stage8DeleteRequested[$id]=true' <<< "$RECORD")"; save_journal
      aws_call rds delete-db-snapshot --db-snapshot-identifier "$snapshot_id" --output json >/dev/null
    fi
    FINAL_CLEANUP_CHANGED=true
    wait_for 8 "additional manual snapshot $snapshot_id deletion" db-snapshot-deleted --db-snapshot-identifier "$snapshot_id"
  done < <(jq -c '.[]' <<< "$scope")
  stage_eight_snapshots
  [[ "$(jq '.manual|length' <<< "$FINAL_SNAPSHOTS")" == 0 ]] \
    || die 'Stage 8 manual snapshots remain or appeared after approval; rerun for a fresh scoped review.'
  verify_purged_backups
  interfaces="$(aws_call ec2 describe-network-interfaces --filters "Name=group-id,Values=$QUARANTINE" --output json)"
  jq -e '.NetworkInterfaces|type=="array" and length==0' <<< "$interfaces" >/dev/null \
    || die 'Stage 8 quarantine ENIs remain; investigate before claiming completion.'
  source_quarantine="$(jq -er '.quarantineSecurityGroup // ""' "$RUN_DIR/network-fence.json")"
  if [[ -n "$source_quarantine" ]]; then
    [[ "$source_quarantine" =~ ^sg-[a-f0-9]+$ && "$source_quarantine" != "$QUARANTINE" ]] \
      || die 'Stage 8 saved original quarantine scope is invalid; investigate without repinning it.'
    source_groups="$(aws_call ec2 describe-security-groups --filters "Name=group-id,Values=$source_quarantine" --output json)"
    jq -e '.SecurityGroups|type=="array" and length==0' <<< "$source_groups" >/dev/null \
      || die 'Stage 8 original-source quarantine SG still exists. Review the approved original-release workflow; it is not auto-deleted here.'
  else
    progress 8 'Legacy source quarantine SG ID is not recorded; only its regional run-tag inventory can be checked. This is a coverage limitation.'
  fi
  for key in dr-run dr-restore; do
    tagged="$(aws_call resourcegroupstaggingapi get-resources --tag-filters "Key=$key,Values=$RUN_ID" --output json)" \
      || die 'Stage 8 tagged-resource audit failed. Check tag:GetResources permission; no complete-cleanup claim can be made.'
    mappings="$(jq -ce '.ResourceTagMappingList | select(type=="array")' <<< "$tagged")" \
      || die 'Stage 8 tagged-resource inventory is invalid.'
    if [[ "$(jq length <<< "$mappings")" != 0 ]]; then
      jq -r '.[].ResourceARN | "Run-tagged resource still reported: " + .' <<< "$mappings" >&2
      die 'Stage 8 run-tagged resources remain (or tag inventory is still converging). Review live ownership and retry; unrelated or unsupported resources are never auto-deleted.'
    fi
  done
  for resource in "$PRIMARY" "$REPLICA"; do
    progress 8 "Verified absent: DB $resource, its retained/system backups and regional manual snapshots."
  done
  progress 8 'Final scoped audit passed. No attributable leftovers found in this account/region; cross-region copies, untagged unknown resources and evidence are outside this claim.'
  if [[ "$FINAL_CLEANUP_CHANGED" == true ]]; then
    RECORD="$(jq '.stage8VerifiedAt=(now|todateiso8601)' <<< "$RECORD")"; save_journal
  fi
}
if [[ "$(jq -r '.backupPurgeComplete // false' <<< "$RECORD")" == true &&
  ( "$(jq -r '.status' <<< "$RECORD")" == complete || "$(jq -r '.status' <<< "$RECORD")" == approved ) ]]; then
  progress 7 'Checking completed retirement: DB, SG and run-owned backup absence (read-only).'
  [[ "$(jq --arg primary "$PRIMARY" --arg replica "$REPLICA" \
    '[.DBInstances[] | select(.DBInstanceIdentifier==$primary or .DBInstanceIdentifier==$replica)]|length' \
    <<< "$INSTANCES")" == 0 && "$(jq '.SecurityGroups|length' <<< "$SECURITY_GROUPS")" == 0 ]] \
    || die 'Completed retirement resources exist again; investigate, do not delete.'
  verify_purged_backups
  stage_eight_cleanup
  if [[ "$(jq -r '.status' <<< "$RECORD")" != complete ]]; then
    RECORD="$(jq '.status="complete" | .completedAt=(now|todateiso8601) | .stage8VerifiedAt=(now|todateiso8601) |
      .stage8Scope="pinned-restored-resources-and-regional-run-tags"' <<< "$RECORD")"; save_journal
    write_retirement_report
    retirement_summary 'Earlier DB/backup retirement was retained; stage 8 is now verified and retirement is complete.'
    exit 0
  fi
  RECORD="$(jq '.stage8VerifiedAt=(if .stage8VerifiedAt then .stage8VerifiedAt else (now|todateiso8601) end) |
    .stage8Scope="pinned-restored-resources-and-regional-run-tags"' <<< "$RECORD")"; save_journal
  write_retirement_report
  if [[ "$FINAL_CLEANUP_CHANGED" == true ]]; then
    retirement_summary 'Prior retirement retained; additionally approved restored-pair manual snapshots were purged and stage 8 reverified.'
  else
    retirement_summary 'Already completed: this was a read-only verification. No changes made.'
  fi
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
OWNER="$(jq -er '.appOwner | select(type=="string" and test("\\S"))' <<< "$CONTEXT")"
printf 'Reusing signed-off app owner for retirement: %s\n' "$OWNER"
bb3_prompt_read EVIDENCE 'Actual retirement/data retention approval reference: '
[[ -n "${EVIDENCE//[[:space:]]/}" ]] || die 'Retirement approval reference is required.'
APPROVAL=''
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
RECORD="$(jq '.backupPurgeComplete=true' <<< "$RECORD")"; save_journal
stage_eight_cleanup
RECORD="$(jq '.status="complete" | .completedAt=(now|todateiso8601) | .stage8VerifiedAt=(now|todateiso8601) |
  .stage8Scope="pinned-restored-resources-and-regional-run-tags"' <<< "$RECORD")"; save_journal
write_retirement_report
retirement_summary