#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bb3-prompt.sh
source "$HERE/bb3-prompt.sh"
ROOT="$(cd "$HERE/../../.." && pwd)"
CONFIG="${BB3_SANDBOX_CONFIG:-$ROOT/iac/sandbox.env}"
LEDGER="${BB3_LEDGER_DIR:-$ROOT/evidence/bb3-secret-endpoints}"
MODE=cutover
RUN_SELECTION=latest
RELEASE_QUARANTINE=false
CLEANUP_FAILBACK_QUARANTINE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --failback)
      MODE=failback
      shift
      if [[ $# -gt 0 && "$1" != --* ]]; then RUN_SELECTION="$1"; shift; fi
      ;;
    --release-quarantine) RELEASE_QUARANTINE=true; shift ;;
    --cleanup-failback-quarantine) CLEANUP_FAILBACK_QUARANTINE=true; shift ;;
    *) echo 'Usage: fence-confirm.sh [--failback [DR-ID|latest]] [--release-quarantine | --cleanup-failback-quarantine]' >&2; exit 2 ;;
  esac
done
if [[ "$CLEANUP_FAILBACK_QUARANTINE" == true ]]; then
  [[ "$MODE" == failback && "$RUN_SELECTION" =~ ^DR-[A-Za-z0-9_-]{1,120}$ && "$RELEASE_QUARANTINE" == false ]] \
    || { echo 'Cleanup requires --failback DR-ID (not latest) and cannot use --release-quarantine.' >&2; exit 2; }
fi
[[ -f "$CONFIG" ]] || { echo 'Missing ignored iac/sandbox.env.' >&2; exit 2; }
# shellcheck source=/dev/null
source "$CONFIG"
unset AWS_DEFAULT_PROFILE TF_VAR_terrakube_token
PROFILE="${TF_VAR_aws_profile:-}"
REGION="${TF_VAR_region:-}"
ACCOUNT="${TF_VAR_account_id:-}"
[[ "$PROFILE" =~ ^(lab_sandbox|pa_aws_sandbox|pa_iam_aws_sandbox)$ \
  && "$REGION" == ap-southeast-1 && "$ACCOUNT" =~ ^[0-9]{12}$ \
  && "${ENV:-}" =~ ^(dev|uat)$ ]] || { echo 'Only dev/uat sandbox is allowed.' >&2; exit 2; }
[[ -z "${AWS_ACCESS_KEY_ID:-}${AWS_SECRET_ACCESS_KEY:-}${AWS_SESSION_TOKEN:-}" ]] \
  || { echo 'Unset exported AWS credentials.' >&2; exit 2; }
CALLER="$(aws --profile "$PROFILE" --region "$REGION" --no-cli-pager sts get-caller-identity --query Account --output text)"
[[ "$CALLER" == "$ACCOUNT" ]] || { echo 'AWS caller does not match the configured sandbox.' >&2; exit 2; }
[[ -t 0 ]] || { echo 'Run this gate in an interactive terminal.' >&2; exit 2; }
ulimit -c 0
COLOR_RED=''; COLOR_GREEN=''; COLOR_RESET=''
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  COLOR_RED=$'\033[31m'
  COLOR_GREEN=$'\033[32m'
  COLOR_RESET=$'\033[0m'
fi

git -C "$ROOT" check-ignore -q "$LEDGER/check.json" \
  || { echo 'Fence records must be Git-ignored.' >&2; exit 2; }

if [[ "$MODE" == failback ]]; then
  SAVED="$(python3 "$HERE/secret-endpoints.py" --show-run "$LEDGER" "$RUN_SELECTION" "$ACCOUNT" "$REGION")"
  RUN_ID="$(jq -er '.runId' <<< "$SAVED")"
  ACTIVE_PRIMARY="$(jq -er '.db' <<< "$SAVED")"
  ACTIVE_REPLICA="$(jq -r '.replica // empty' <<< "$SAVED")"
  RETURN_PRIMARY="$(jq -er '.source_db' <<< "$SAVED")"
  RETURN_REPLICA="$(jq -r '.source_replica // empty' <<< "$SAVED")"
  RECORD="$LEDGER/$RUN_ID/failback-fence.json"
else
  ACTIVE_PRIMARY="${BB3_SOURCE_PRIMARY_ID:-}"
  ACTIVE_REPLICA="${BB3_SOURCE_REPLICA_ID:-}"
  RETURN_PRIMARY="${BB3_RESTORE_TARGET_PRIMARY_ID:-}"
  RETURN_REPLICA="${BB3_RESTORE_TARGET_REPLICA_ID:-}"
  [[ -n "$RETURN_PRIMARY" && -n "$ACTIVE_PRIMARY" ]] \
    || { echo 'Run guided BB3 discovery first; source and target primary IDs are required.' >&2; exit 2; }
  TARGET_ARN="$(aws --profile "$PROFILE" --region "$REGION" --no-cli-pager rds describe-db-instances \
    --db-instance-identifier "$RETURN_PRIMARY" --query 'DBInstances[0].DBInstanceArn' --output text)"
  RUN_ID="$(aws --profile "$PROFILE" --region "$REGION" --no-cli-pager rds list-tags-for-resource \
    --resource-name "$TARGET_ARN" --query 'TagList[?Key==`dr-restore`].Value | [0]' --output text)"
  [[ "$RUN_ID" =~ ^DR-[A-Za-z0-9_-]{1,120}$ ]] || { echo 'Restored primary has no valid dr-restore run tag.' >&2; exit 2; }
  RECORD="$LEDGER/$RUN_ID/fence.json"
fi

cleanup_failback_quarantine() {
  local network_record="$LEDGER/$RUN_ID/failback-network-fence.json"
  local original_record="$LEDGER/$RUN_ID/network-fence.json"
  local failback_record="$LEDGER/$RUN_ID/failback.json"
  local app_deploy="$LEDGER/$RUN_ID/failback-app-deploy.json"
  local app_health="$LEDGER/$RUN_ID/failback-app-health.json"
  local app_e2e="$LEDGER/$RUN_ID/failback-app-e2e.json"
  local app_fence="$LEDGER/$RUN_ID/failback-fence.json"
  local quarantine source_group journal_status group_json expected_vpc saved_groups groups_json
  local instances interfaces cleanup_owner cleanup_evidence cleanup_approval temporary app_owner
  jq -e --arg run "$RUN_ID" --arg account "$ACCOUNT" --arg region "$REGION" \
    --arg primary "$ACTIVE_PRIMARY" --arg replica "$ACTIVE_REPLICA" \
    --arg target "$RETURN_PRIMARY" --arg target_replica "$RETURN_REPLICA" '
    .runId==$run and .account==$account and .region==$region and
    .operation=="failback" and .status=="complete" and
    .source_db==$primary and (.source_replica // "")==$replica and
    .db==$target and (.replica // "")==$target_replica' "$failback_record" >/dev/null \
    || { echo 'Complete matching endpoint failback is required for cleanup.' >&2; return 2; }
  [[ -f "$app_fence" && -f "$app_deploy" && -f "$app_health" && -f "$app_e2e" \
    && -f "$LEDGER/$RUN_ID/failback-app-deploy.log" ]] \
    || { echo 'Failback fence, sanitized deployment log, and complete app deployment, health, and transaction journals are required for cleanup.' >&2; return 2; }
  jq -e --arg run "$RUN_ID" --arg account "$ACCOUNT" --arg region "$REGION" \
    --arg primary "$ACTIVE_PRIMARY" --arg replica "$ACTIVE_REPLICA" \
    --arg target "$RETURN_PRIMARY" --arg target_replica "$RETURN_REPLICA" '
    .runId==$run and .mode=="failback" and .account==$account and .region==$region and
    .status=="owner-confirmed" and .activePrimary==$primary and (.activeReplica // "")==$replica and
    .returnPrimary==$target and (.returnReplica // "")==$target_replica and
    .fenceVerified==true and .existingSessionsClosed==true and (.appOwner|type=="string" and test("\\S"))' \
    "$app_fence" >/dev/null \
    || { echo 'Matching owner-confirmed failback fence and session closure are required for cleanup.' >&2; return 2; }
  app_owner="$(jq -er '.appOwner' "$app_fence")"
  jq -e --arg run "$RUN_ID" --arg account "$ACCOUNT" --arg region "$REGION" \
    --arg primary "$(jq -er '.oldHost' "$LEDGER/$RUN_ID/cutover.json")" \
    --arg replica "$(jq -er '.oldReplicaHost' "$LEDGER/$RUN_ID/cutover.json")" \
    --arg owner "$app_owner" --arg evidence "evidence/bb3-secret-endpoints/$RUN_ID/failback-app-deploy.log" \
    '.runId==$run and .operation=="failback" and .account==$account and .region==$region and
     .mode=="manual" and .status=="owner-confirmed" and .appOwner==$owner and .evidenceRef==$evidence and
     (.appOwner|type=="string" and test("\\S")) and
      .servicesConverged==true and
     .primaryHost==$primary and .replicaHost==$replica' "$app_deploy" >/dev/null \
    || { echo 'Matching manual failback deployment/convergence attestation is required for cleanup.' >&2; return 2; }
  jq -e --arg run "$RUN_ID" --arg account "$ACCOUNT" --arg region "$REGION" \
    --arg primary "$(jq -er '.oldHost' "$LEDGER/$RUN_ID/cutover.json")" \
    --arg replica "$(jq -er '.oldReplicaHost' "$LEDGER/$RUN_ID/cutover.json")" \
    --argjson deployment "$(jq -c . "$app_deploy")" \
    '.runId==$run and .operation=="failback" and .account==$account and .region==$region and
     .status=="owner-confirmed" and .appOwner==$deployment.appOwner and .healthVerified==true and
     (.evidenceRef|type=="string" and test("\\S") and
       (ascii_downcase|test("^\\s*(y|yes|n|no|true|false|ok)\\s*$")|not)) and
     (.healthCheckAt|type=="string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?\\+00:00$")) and
     .primaryHost==$primary and .replicaHost==$replica' "$app_health" >/dev/null \
    || { echo 'Matching original-pair failback health attestation is required for cleanup.' >&2; return 2; }
  jq -e --arg run "$RUN_ID" --arg account "$ACCOUNT" --arg region "$REGION" \
    --arg primary "$(jq -er '.oldHost' "$LEDGER/$RUN_ID/cutover.json")" \
    --arg replica "$(jq -er '.oldReplicaHost' "$LEDGER/$RUN_ID/cutover.json")" \
    --argjson deployment "$(jq -c . "$app_deploy")" \
    '.runId==$run and .operation=="failback" and .account==$account and .region==$region and
     .status=="owner-confirmed" and .appOwner==$deployment.appOwner and
     .businessTransactionVerified==true and
     (.transactionRef|type=="string" and test("\\S") and
       (ascii_downcase|test("^\\s*(y|yes|n|no|true|false|ok)\\s*$")|not)) and
     (.transactionAt|type=="string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?\\+00:00$")) and
     .primaryHost==$primary and .replicaHost==$replica' "$app_e2e" >/dev/null \
    || { echo 'Matching original-pair failback transaction/readback attestation is required for cleanup.' >&2; return 2; }
  jq -e --arg run "$RUN_ID" --arg account "$ACCOUNT" --arg region "$REGION" \
    --arg primary "$RETURN_PRIMARY" --arg replica "$RETURN_REPLICA" '
    .runId==$run and .mode=="cutover" and .account==$account and .region==$region and
    .status=="released" and .activePrimary==$primary and (.activeReplica // "")==$replica and
    (.quarantineSecurityGroup|type=="string" and test("^sg-[a-f0-9]+$"))' "$original_record" >/dev/null \
    || { echo 'Released matching original network fence is required for cleanup.' >&2; return 2; }
  jq -e --arg run "$RUN_ID" --arg account "$ACCOUNT" --arg region "$REGION" \
    --arg primary "$ACTIVE_PRIMARY" --arg replica "$ACTIVE_REPLICA" '
    .runId==$run and .mode=="failback" and .account==$account and .region==$region and
    .activePrimary==$primary and (.activeReplica // "")==$replica and
    (.status=="attached" or .status=="deleted") and
    (.quarantineSecurityGroup|type=="string" and test("^sg-[a-f0-9]+$")) and
    (.previousPrimarySecurityGroups|type=="array" and length>0) and
    (.previousReplicaSecurityGroups|type=="array") and
    ($replica=="" or (.previousReplicaSecurityGroups|length)>0)' "$network_record" >/dev/null \
    || { echo 'Matching attached/deleted failback network fence is required for cleanup.' >&2; return 2; }
  quarantine="$(jq -er '.quarantineSecurityGroup' "$network_record")"
  source_group="$(jq -er '.quarantineSecurityGroup' "$original_record")"
  [[ "$quarantine" != "$source_group" && "$ACTIVE_PRIMARY" != "$RETURN_PRIMARY" \
    && "$ACTIVE_PRIMARY" != "$RETURN_REPLICA" && ( -z "$ACTIVE_REPLICA" \
    || ( "$ACTIVE_REPLICA" != "$RETURN_PRIMARY" && "$ACTIVE_REPLICA" != "$RETURN_REPLICA" ) ) ]] \
    || { echo 'Source and restored pair identities/quarantine SGs must be distinct.' >&2; return 2; }
  journal_status="$(jq -er '.status' "$network_record")"
  instances="$(aws --profile "$PROFILE" --region "$REGION" --no-cli-pager rds describe-db-instances --output json)" || return 2
  jq -e --arg sg "$quarantine" '.DBInstances | type=="array" and
    all(.[]; all(.VpcSecurityGroups[]?; .VpcSecurityGroupId!=$sg))' <<< "$instances" >/dev/null \
    || { echo 'Quarantine SG is still attached to a DB; retire DBs through the separately approved process first.' >&2; return 2; }
  interfaces="$(aws --profile "$PROFILE" --region "$REGION" --no-cli-pager ec2 describe-network-interfaces \
    --filters "Name=group-id,Values=$quarantine" --output json)" || return 2
  jq -e '.NetworkInterfaces | type=="array" and length==0' <<< "$interfaces" >/dev/null \
    || { echo 'Quarantine SG still has network interfaces; no deletion made.' >&2; return 2; }
  group_json="$(aws --profile "$PROFILE" --region "$REGION" --no-cli-pager ec2 describe-security-groups \
    --filters "Name=group-id,Values=$quarantine" --output json)" || return 2
  if [[ "$journal_status" == deleted ]]; then
    jq -e '.SecurityGroups | type=="array" and length==0' <<< "$group_json" >/dev/null \
      && jq -e --arg owner "$app_owner" 'def attestation: type=="string" and test("\\S") and
        (ascii_downcase|test("^\\s*(y|yes|n|no|true|false|ok)\\s*$")|not);
        (.cleanupOwner|attestation) and .cleanupOwner==$owner and (.cleanupEvidenceRef|attestation) and
        .postFailbackAppValidated==true and (.cleanupApprovedAt|type=="string" and length>0) and
        (.deletedAt|type=="string" and length>0)' "$network_record" >/dev/null \
      || { echo 'Deleted journal is incomplete or quarantine SG exists again; refusing cleanup.' >&2; return 2; }
    echo 'Failback quarantine already deleted and absence verified; no changes made.'
    return 0
  fi
  jq -e --arg sg "$quarantine" --arg run "$RUN_ID" '.SecurityGroups | type=="array" and length==1 and
    .[0].GroupId==$sg and (.[0].VpcId|type=="string" and test("^vpc-[A-Za-z0-9]+$")) and
    any(.[0].Tags[]?; .Key=="dr-run" and .Value==$run) and
    any(.[0].Tags[]?; .Key=="dr-role" and .Value=="quarantine") and
    (.[0].IpPermissions|type=="array" and length==0)' <<< "$group_json" >/dev/null \
    || { echo 'Quarantine SG absent before recorded deletion, mismatched, or has ingress; state unknown, refusing cleanup.' >&2; return 2; }
  expected_vpc="$(jq -r '.vpcId // empty' "$network_record")"
  if [[ -z "$expected_vpc" ]]; then
    saved_groups="$(jq -ce '[.previousPrimarySecurityGroups[], .previousReplicaSecurityGroups[]] | unique |
      select(length>0 and all(.[]; type=="string" and test("^sg-[A-Za-z0-9-]+$")))' "$original_record")" || return 2
    local -a group_ids=()
    while IFS= read -r group_id; do group_ids+=("$group_id"); done < <(jq -r '.[]' <<< "$saved_groups")
    groups_json="$(aws --profile "$PROFILE" --region "$REGION" --no-cli-pager ec2 describe-security-groups \
      --group-ids "${group_ids[@]}" --output json)" || return 2
    expected_vpc="$(jq -er --argjson groups "$saved_groups" '
      select(([.SecurityGroups[].GroupId]|sort)==($groups|sort)) |
      [.SecurityGroups[].VpcId] | unique | select(length==1) | .[0] | select(type=="string" and length>0)' \
      <<< "$groups_json")" || { echo 'Cannot verify original saved SG VPC; refusing cleanup.' >&2; return 2; }
  fi
  jq -e --arg vpc "$expected_vpc" '.SecurityGroups[0].VpcId==$vpc' <<< "$group_json" >/dev/null \
    || { echo 'Quarantine SG VPC does not match the recorded/original VPC.' >&2; return 2; }
  printf 'Cleanup only deletes the detached restored-pair quarantine SG %s. It does not retire DBs or restore SG attachments.\n' "$quarantine"
  bb3_prompt_read cleanup_owner 'Post-failback app validation/signoff owner: ' || return 2
  bb3_prompt_read cleanup_evidence 'Actual post-failback app validation/signoff evidence reference: ' || return 2
  jq -en --arg owner "$cleanup_owner" --arg evidence "$cleanup_evidence" '
    def attestation: test("\\S") and (ascii_downcase|test("^\\s*(y|yes|n|no|true|false|ok)\\s*$")|not);
    ($owner|attestation) and ($evidence|attestation)' >/dev/null \
    || { echo 'Nonblank owner and actual evidence reference are required; generic approvals are not evidence.' >&2; return 2; }
  [[ "$cleanup_owner" == "$(jq -er '.appOwner' "$app_deploy")" ]] \
    || { echo 'Cleanup owner must match the completed failback app validation owner.' >&2; return 2; }
  bb3_prompt_token_read cleanup_approval 'Type ' DELETE-FAILBACK-QUARANTINE \
    ' to confirm post-failback app signoff and delete: ' || return 2
  [[ "$cleanup_approval" == DELETE-FAILBACK-QUARANTINE ]] \
    || { echo 'Cleanup not approved; no deletion made.' >&2; return 2; }
  temporary="$(mktemp "$(dirname "$network_record")/.cleanup.XXXXXX")"
  jq --arg owner "$cleanup_owner" --arg evidence "$cleanup_evidence" --arg vpc "$expected_vpc" '
    .cleanupOwner=$owner | .cleanupEvidenceRef=$evidence | .postFailbackAppValidated=true |
    .cleanupApprovedAt=(now|todateiso8601) | .vpcId=$vpc' "$network_record" > "$temporary"
  chmod 600 "$temporary"
  mv "$temporary" "$network_record"
  aws --profile "$PROFILE" --region "$REGION" --no-cli-pager ec2 delete-security-group --group-id "$quarantine" >/dev/null || return 2
  group_json="$(aws --profile "$PROFILE" --region "$REGION" --no-cli-pager ec2 describe-security-groups \
    --filters "Name=group-id,Values=$quarantine" --output json)" || return 2
  jq -e '.SecurityGroups | type=="array" and length==0' <<< "$group_json" >/dev/null \
    || { echo 'Deletion not verified; journal remains attached for investigation.' >&2; return 2; }
  temporary="$(mktemp "$(dirname "$network_record")/.cleanup.XXXXXX")"
  jq '.status="deleted" | .deletedAt=(now|todateiso8601)' "$network_record" > "$temporary"
  chmod 600 "$temporary"
  mv "$temporary" "$network_record"
  echo 'Restored-pair failback quarantine deleted; DBs, snapshots and prior SG sets unchanged.'
}

if [[ "$CLEANUP_FAILBACK_QUARANTINE" == true ]]; then
  [[ "$RUN_ID" == "$RUN_SELECTION" ]] \
    || { echo 'Saved cutover run ID does not match the explicit cleanup selection.' >&2; exit 2; }
  cleanup_failback_quarantine
  exit 0
fi
EXISTING_RECORD=''
APP_OWNER=''
if [[ -e "$RECORD" ]]; then
  EXISTING_RECORD="$(jq -ce --arg run "$RUN_ID" --arg mode "$MODE" --arg account "$ACCOUNT" --arg region "$REGION" \
    'select(.runId==$run and .mode==$mode and .account==$account and .region==$region and .status=="owner-confirmed")' "$RECORD")" \
    || { echo 'Existing fence journal is incomplete or belongs to a different run/account.' >&2; exit 2; }
  [[ "$(jq -er '.activePrimary' <<< "$EXISTING_RECORD")" == "$ACTIVE_PRIMARY" \
    && "$(jq -r '.activeReplica // empty' <<< "$EXISTING_RECORD")" == "$ACTIVE_REPLICA" \
    && "$(jq -er '.returnPrimary' <<< "$EXISTING_RECORD")" == "$RETURN_PRIMARY" \
    && "$(jq -r '.returnReplica // empty' <<< "$EXISTING_RECORD")" == "$RETURN_REPLICA" ]] \
    || { echo 'Existing fence journal DB IDs do not match this selection.' >&2; exit 2; }
  APP_OWNER="$(jq -er '.appOwner' <<< "$EXISTING_RECORD")"
fi
NETWORK_RECORD="$LEDGER/$RUN_ID/network-fence.json"
[[ "$MODE" != failback ]] || NETWORK_RECORD="$LEDGER/$RUN_ID/failback-network-fence.json"
BASELINE_STORE="$HERE/baselines"
QUARANTINE_SG=''
PREVIOUS_PRIMARY_GROUPS='[]'
PREVIOUS_REPLICA_GROUPS='[]'
SESSIONS_CLOSED=false

inspect_db() {
  aws --profile "$PROFILE" --region "$REGION" --no-cli-pager rds describe-db-instances \
    --db-instance-identifier "$1" --query 'DBInstances[0]' --output json
}

group_ids_for_db() {
  aws --profile "$PROFILE" --region "$REGION" --no-cli-pager rds describe-db-instances \
    --db-instance-identifier "$1" --query 'DBInstances[0].VpcSecurityGroups[].VpcSecurityGroupId' --output json
}

wait_for_quarantine_attachment() {
  local instance_id="$1" attached attempt=0
  while ((attempt < 8)); do
    attempt=$((attempt + 1))
    attached="$(aws --profile "$PROFILE" --region "$REGION" --no-cli-pager rds describe-db-instances \
      --db-instance-identifier "$instance_id" --query 'DBInstances[0].VpcSecurityGroups' --output json)" || return 1
    if jq -e --arg sg "$QUARANTINE_SG" \
      'length==1 and .[0].VpcSecurityGroupId==$sg and .[0].Status=="active"' <<< "$attached" >/dev/null; then
      return 0
    fi
  done
  return 1
}

load_baseline_groups() {
  local latest capture_name capture_dir expected actual primary replica relative
  latest="$BASELINE_STORE/latest.json"
  [[ -f "$latest" ]] || { echo 'A captured source baseline is required before fencing.' >&2; return 1; }
  capture_name="$(jq -er '.directory | select(test("^[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9]+$"))' "$latest")" || return 1
  capture_dir="$BASELINE_STORE/$capture_name"
  [[ "$(jq -r '.status' "$latest")" == complete && -f "$capture_dir/manifest.json" ]] || return 1
  cmp -s "$latest" "$capture_dir/capture.json" || { echo 'Latest baseline reference does not match the captured metadata.' >&2; return 1; }
  for relative in capture.json primary/baseline.json; do
    expected="$(jq -er --arg path "$relative" '.files[] | select(.path==$path) | .sha256' "$capture_dir/manifest.json")" || return 1
    actual="$(shasum -a 256 "$capture_dir/$relative" | awk '{print $1}')" || return 1
    [[ "$actual" == "$expected" ]] || { echo "Baseline integrity check failed: $relative." >&2; return 1; }
  done
  primary="$(jq -c . "$capture_dir/primary/baseline.json")"
  [[ "$(jq -r '.source' <<< "$primary")" == "$ACTIVE_PRIMARY" \
    && "$(jq -r '.account' <<< "$primary")" == "$ACCOUNT" \
    && "$(jq -r '.region' <<< "$primary")" == "$REGION" ]] \
    || { echo 'Captured primary baseline does not match the active DB/account/region.' >&2; return 1; }
  PREVIOUS_PRIMARY_GROUPS="$(jq -ce '[.instance.VpcSecurityGroups[].VpcSecurityGroupId] | select(length>0)' <<< "$primary")" || return 1
  if [[ -n "$ACTIVE_REPLICA" ]]; then
    relative=replica/baseline.json
    expected="$(jq -er --arg path "$relative" '.files[] | select(.path==$path) | .sha256' "$capture_dir/manifest.json")" || return 1
    actual="$(shasum -a 256 "$capture_dir/$relative" | awk '{print $1}')" || return 1
    [[ "$actual" == "$expected" ]] || { echo 'Replica baseline integrity check failed.' >&2; return 1; }
    replica="$(jq -c . "$capture_dir/replica/baseline.json")"
    [[ "$(jq -r '.source' <<< "$replica")" == "$ACTIVE_REPLICA" ]] \
      || { echo 'Captured replica baseline does not match the selected replica.' >&2; return 1; }
    PREVIOUS_REPLICA_GROUPS="$(jq -ce '[.instance.VpcSecurityGroups[].VpcSecurityGroupId] | select(length>0)' <<< "$replica")" || return 1
  fi
}

verify_quarantine_group() {
  local group_json
  group_json="$(aws --profile "$PROFILE" --region "$REGION" --no-cli-pager ec2 describe-security-groups \
    --group-ids "$1" --output json)" || return 1
  jq -e --arg group "$1" --arg run "$RUN_ID" --arg role quarantine --arg vpc "$2" '
    (.SecurityGroups|length)==1 and .SecurityGroups[0].GroupId==$group and
    .SecurityGroups[0].VpcId==$vpc and
    any(.SecurityGroups[0].Tags[]?; .Key=="dr-run" and .Value==$run) and
    any(.SecurityGroups[0].Tags[]?; .Key=="dr-role" and .Value==$role) and
    ((.SecurityGroups[0].IpPermissions // [])|length)==0
  ' <<< "$group_json" >/dev/null
}

write_network_record() {
  local status="$1" temporary
  mkdir -p "$(dirname "$NETWORK_RECORD")"
  chmod 700 "$LEDGER" "$(dirname "$NETWORK_RECORD")"
  temporary="$(mktemp "$(dirname "$NETWORK_RECORD")/.network-fence.XXXXXX")"
  jq -n --arg run "$RUN_ID" --arg mode "$MODE" --arg account "$ACCOUNT" --arg region "$REGION" \
    --arg vpc "$(jq -er '.DBSubnetGroup.VpcId' <<< "$ACTIVE_PRIMARY_JSON")" \
    --arg primary "$ACTIVE_PRIMARY" --arg replica "$ACTIVE_REPLICA" --arg sg "$QUARANTINE_SG" \
    --arg status "$status" --argjson primary_groups "$PREVIOUS_PRIMARY_GROUPS" \
    --argjson replica_groups "$PREVIOUS_REPLICA_GROUPS" \
    '{runId:$run,mode:$mode,account:$account,region:$region,activePrimary:$primary,vpcId:$vpc,
      activeReplica:(if $replica=="" then null else $replica end),quarantineSecurityGroup:$sg,
      previousPrimarySecurityGroups:$primary_groups,previousReplicaSecurityGroups:$replica_groups,
      status:$status,recordedAt:(now|todateiso8601)}' > "$temporary"
  chmod 600 "$temporary"
  mv "$temporary" "$NETWORK_RECORD"
}

apply_quarantine_group() {
  local primary_groups replica_groups vpc_id group_name created current_groups instance_id
  local -a instance_ids=()
  local primary_display replica_display apply_approval
  vpc_id="$(jq -er '.DBSubnetGroup.VpcId' <<< "$ACTIVE_PRIMARY_JSON")" || return 1
  if [[ -n "$ACTIVE_REPLICA" ]]; then
    [[ "$(jq -er '.DBSubnetGroup.VpcId' <<< "$ACTIVE_REPLICA_JSON")" == "$vpc_id" ]] \
      || { echo 'Active DB pair is not in the same VPC.' >&2; return 1; }
  fi
  primary_groups="$(group_ids_for_db "$ACTIVE_PRIMARY")"
  replica_groups='[]'
  if [[ -n "$ACTIVE_REPLICA" ]]; then
    replica_groups="$(group_ids_for_db "$ACTIVE_REPLICA")"
  fi
  primary_display="$(jq -r 'join(", ")' <<< "$primary_groups")"
  replica_display='none'
  [[ -z "$ACTIVE_REPLICA" ]] || replica_display="$(jq -r 'join(", ")' <<< "$replica_groups")"
  printf '\n%sCurrent primary SGs for %s:%s %s\n' "$COLOR_RED" "$ACTIVE_PRIMARY" "$COLOR_RESET" "$primary_display"
  if [[ -n "$ACTIVE_REPLICA" ]]; then
    printf '%sCurrent replica SGs for %s:%s %s\n' "$COLOR_RED" "$ACTIVE_REPLICA" "$COLOR_RESET" "$replica_display"
  else
    printf '%sCurrent replica SGs:%s %s\n' "$COLOR_RED" "$COLOR_RESET" "$replica_display"
  fi
  if [[ -f "$NETWORK_RECORD" ]]; then
    printf '%sWARNING: The existing run-scoped quarantine SG will be reused; only DBs not already attached to it will be modified.%s\n' \
      "$COLOR_RED" "$COLOR_RESET"
    printf '%sReusing quarantine SG: %s%s\n' "$COLOR_GREEN" \
      "$(jq -er '.quarantineSecurityGroup' "$NETWORK_RECORD")" "$COLOR_RESET"
  else
    printf '%sWARNING: A NEW run-scoped quarantine SG will be created and replace these SG attachments.%s\n' \
      "$COLOR_RED" "$COLOR_RESET"
    printf '%sReplacement SG: no ingress rules%s\n' "$COLOR_GREEN" "$COLOR_RESET"
  fi
  printf 'The active DBs will use only the quarantine SG. This blocks new connections; existing sessions may continue. Return DB SGs will not change.\n'
  bb3_prompt_read apply_approval 'Apply this quarantine? [y/N]: '
  [[ "$apply_approval" =~ ^[Yy]$ ]] || { echo 'Quarantine SG not applied.' >&2; return 2; }
  if [[ -f "$NETWORK_RECORD" ]]; then
    jq -e --arg run "$RUN_ID" --arg mode "$MODE" --arg account "$ACCOUNT" --arg region "$REGION" \
      --arg primary "$ACTIVE_PRIMARY" --arg replica "$ACTIVE_REPLICA" \
      '.runId==$run and .mode==$mode and .account==$account and .region==$region and .activePrimary==$primary and
      (.activeReplica // "")==$replica and (.status=="prepared" or .status=="submitted" or .status=="attached") and
      (.previousPrimarySecurityGroups|type=="array" and length>0) and
      ($replica=="" or (.previousReplicaSecurityGroups|type=="array" and length>0))' \
      "$NETWORK_RECORD" >/dev/null \
      || { echo 'Network fence journal does not match this run or is not resumable.' >&2; return 1; }
    QUARANTINE_SG="$(jq -er '.quarantineSecurityGroup' "$NETWORK_RECORD")"
    PREVIOUS_PRIMARY_GROUPS="$(jq -ce '.previousPrimarySecurityGroups' "$NETWORK_RECORD")"
    PREVIOUS_REPLICA_GROUPS="$(jq -ce '.previousReplicaSecurityGroups' "$NETWORK_RECORD")"
  elif [[ "$MODE" == failback ]]; then
    jq -e 'type=="array" and length>0' <<< "$primary_groups" >/dev/null || return 1
    if [[ -n "$ACTIVE_REPLICA" ]]; then
      jq -e 'type=="array" and length>0' <<< "$replica_groups" >/dev/null || return 1
    fi
    PREVIOUS_PRIMARY_GROUPS="$primary_groups"
    PREVIOUS_REPLICA_GROUPS="$replica_groups"
    vpc_id="$(jq -er '.DBSubnetGroup.VpcId' <<< "$ACTIVE_PRIMARY_JSON")" \
      || { echo 'Active restored primary has no VPC ID; refusing to create a quarantine group.' >&2; return 1; }
    if [[ -n "$ACTIVE_REPLICA" ]]; then
      [[ "$(jq -er '.DBSubnetGroup.VpcId' <<< "$ACTIVE_REPLICA_JSON")" == "$vpc_id" ]] \
        || { echo 'Active restored DB pair is not in the same VPC.' >&2; return 1; }
    fi
    group_name="dr-bb3-${ENV}-failback-quarantine-${RUN_ID//_/-}"
    created="$(aws --profile "$PROFILE" --region "$REGION" --no-cli-pager ec2 create-security-group \
      --group-name "$group_name" --description "Temporary BB3 failback quarantine for $RUN_ID" --vpc-id "$vpc_id" \
      --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$group_name},{Key=dr-run,Value=$RUN_ID},{Key=dr-role,Value=quarantine}]" \
      --query GroupId --output text)" || return 1
    [[ "$created" =~ ^sg-[a-f0-9]+$ ]] || { echo 'AWS did not return a valid failback quarantine SG ID.' >&2; return 1; }
    QUARANTINE_SG="$created"
    write_network_record prepared
  else
    load_baseline_groups || return 1
    vpc_id="$(jq -er '.DBSubnetGroup.VpcId' <<< "$ACTIVE_PRIMARY_JSON")" \
      || { echo 'Active primary has no VPC ID; refusing to create a quarantine group.' >&2; return 1; }
    if [[ -n "$ACTIVE_REPLICA" ]]; then
      [[ "$(jq -er '.DBSubnetGroup.VpcId' <<< "$ACTIVE_REPLICA_JSON")" == "$vpc_id" ]] \
        || { echo 'Active DB pair is not in the same VPC.' >&2; return 1; }
    fi
    group_name="dr-bb3-${ENV}-quarantine-${RUN_ID//_/-}"
    created="$(aws --profile "$PROFILE" --region "$REGION" --no-cli-pager ec2 create-security-group \
      --group-name "$group_name" --description "Temporary BB3 DR quarantine for $RUN_ID" --vpc-id "$vpc_id" \
      --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$group_name},{Key=dr-run,Value=$RUN_ID},{Key=dr-role,Value=quarantine}]" \
      --query GroupId --output text)" || return 1
    [[ "$created" =~ ^sg-[a-f0-9]+$ ]] || { echo 'AWS did not return a valid quarantine SG ID.' >&2; return 1; }
    QUARANTINE_SG="$created"
    write_network_record prepared
  fi
  vpc_id="$(jq -er '.DBSubnetGroup.VpcId' <<< "$ACTIVE_PRIMARY_JSON")" \
    || { echo 'Active primary has no VPC ID; refusing to attach quarantine SG.' >&2; return 1; }
  verify_quarantine_group "$QUARANTINE_SG" "$vpc_id" \
    || { echo 'Quarantine SG is missing, belongs to another run, or has ingress rules.' >&2; return 1; }
  instance_ids=("$ACTIVE_PRIMARY")
  [[ -z "$ACTIVE_REPLICA" ]] || instance_ids+=("$ACTIVE_REPLICA")
  # Submit both independent SG modifications before waiting, so their AWS apply times overlap.
  for instance_id in "${instance_ids[@]}"; do
    current_groups="$(group_ids_for_db "$instance_id")"
    if ! jq -e --arg sg "$QUARANTINE_SG" 'length==1 and .[0]==$sg' <<< "$current_groups" >/dev/null; then
      aws --profile "$PROFILE" --region "$REGION" --no-cli-pager rds modify-db-instance \
        --db-instance-identifier "$instance_id" --vpc-security-group-ids "$QUARANTINE_SG" \
        --apply-immediately >/dev/null || return 1
    fi
  done
  for instance_id in "${instance_ids[@]}"; do
    bb3_wait 'Waiting for restored quarantine DB availability' aws --profile "$PROFILE" --region "$REGION" --no-cli-pager rds wait db-instance-available \
      --db-instance-identifier "$instance_id" || return 1
    wait_for_quarantine_attachment "$instance_id" \
      || { echo "Quarantine SG attachment is not active on $instance_id after retries." >&2; return 1; }
    current_groups="$(group_ids_for_db "$instance_id")"
    jq -e --arg sg "$QUARANTINE_SG" 'length==1 and .[0]==$sg' <<< "$current_groups" >/dev/null \
      || { echo "Quarantine SG attachment was not verified on $instance_id." >&2; return 1; }
  done
  write_network_record attached
  FENCE_METHOD=security-group-no-ingress
  FENCE_VERIFIED=true
  printf 'Verified run-scoped no-ingress SG %s is the only SG on the active DB pair. This blocks new connections, not existing sessions.\n' "$QUARANTINE_SG"
}

verify_restored_fence_for_release() {
  local primary_json replica_json vpc_id instance_id
  for instance_id in "$ACTIVE_PRIMARY" "$ACTIVE_REPLICA"; do
    [[ -n "$instance_id" ]] || continue
    [[ "$instance_id" != "$RETURN_PRIMARY" && "$instance_id" != "$RETURN_REPLICA" ]] || return 2
  done
  [[ -n "$EXISTING_RECORD" ]] || { echo 'Saved failback fence is required before source release.' >&2; return 2; }
  jq -e '.fenceMethod=="security-group-no-ingress" and .fenceVerified==true and
    .existingSessionsClosed==true and (.appOwner|type=="string" and length>0)' \
    <<< "$EXISTING_RECORD" >/dev/null || return 2
  QUARANTINE_SG="$(jq -er '.quarantineSecurityGroup' <<< "$EXISTING_RECORD")" || return 2
  jq -e --arg run "$RUN_ID" --arg account "$ACCOUNT" --arg region "$REGION" \
    --arg primary "$ACTIVE_PRIMARY" --arg replica "$ACTIVE_REPLICA" --arg sg "$QUARANTINE_SG" \
    '.runId==$run and .mode=="failback" and .account==$account and .region==$region and
     .activePrimary==$primary and (.activeReplica // "")==$replica and .status=="attached" and
     .quarantineSecurityGroup==$sg and (.previousPrimarySecurityGroups|type=="array" and length>0) and
     ($replica=="" or (.previousReplicaSecurityGroups|type=="array" and length>0))' \
    "$NETWORK_RECORD" >/dev/null || return 2
  primary_json="$(inspect_db "$ACTIVE_PRIMARY")" || return 2
  vpc_id="$(jq -er '.DBSubnetGroup.VpcId' <<< "$primary_json")" || return 2
  jq -e --arg primary "$ACTIVE_PRIMARY" --arg replica "$ACTIVE_REPLICA" \
    '.DBInstanceIdentifier==$primary and .DBInstanceStatus=="available" and
     (.ReadReplicaSourceDBInstanceIdentifier // "")=="" and
     ((.ReadReplicaDBInstanceIdentifiers // [] | sort)==(if $replica=="" then [] else [$replica] end))' \
    <<< "$primary_json" >/dev/null || return 2
  if [[ -n "$ACTIVE_REPLICA" ]]; then
    replica_json="$(inspect_db "$ACTIVE_REPLICA")" || return 2
    jq -e --arg replica "$ACTIVE_REPLICA" --arg primary "$ACTIVE_PRIMARY" --arg vpc "$vpc_id" \
      '.DBInstanceIdentifier==$replica and .DBInstanceStatus=="available" and
       .ReadReplicaSourceDBInstanceIdentifier==$primary and .DBSubnetGroup.VpcId==$vpc' \
      <<< "$replica_json" >/dev/null || return 2
  fi
  verify_quarantine_group "$QUARANTINE_SG" "$vpc_id" || return 2
  for instance_id in "$ACTIVE_PRIMARY" "$ACTIVE_REPLICA"; do
    [[ -n "$instance_id" ]] || continue
    wait_for_quarantine_attachment "$instance_id" || return 2
  done
}

wait_for_saved_security_groups() {
  local instance_id="$1" expected_groups="$2" attached attempt
  printf 'Waiting for saved SG attachments on %s to become active. DB available alone is not sufficient.\n' "$instance_id"
  for ((attempt=1; attempt<=24; attempt++)); do
    attached="$(aws --profile "$PROFILE" --region "$REGION" --no-cli-pager rds describe-db-instances \
      --db-instance-identifier "$instance_id" --query 'DBInstances[0].VpcSecurityGroups' --output json)" || return 2
    if jq -e --argjson expected "$expected_groups" 'type=="array" and
      ([.[].VpcSecurityGroupId]|sort)==($expected|sort) and all(.[];.Status=="active")' \
      <<< "$attached" >/dev/null; then
      printf 'Verified saved SG set active on %s.\n' "$instance_id"
      return 0
    fi
    printf 'SG attachment verification %s/24 for %s: %s\n' "$attempt" "$instance_id" \
      "$(jq -c '[.[] | {id:.VpcSecurityGroupId,status:.Status}]' <<< "$attached")"
    if ((attempt < 24)); then sleep 5; fi
  done
  printf 'Saved SG set is not active on %s; quarantine SG retained and source release remains incomplete.\n' "$instance_id" >&2
  printf 'Review current SG attachments, then resume: bash iac/lab/bb3-db/bb3-run.sh S3 --only P3-S01 --failback %s --release-quarantine\n' "$RUN_ID" >&2
  return 2
}

release_source_quarantine() {
  local source_primary source_replica source_group source_vpc primary_groups replica_groups current_groups expected_groups instance_id group_json
  local group_count record_status
  local original_record="$LEDGER/$RUN_ID/network-fence.json"
  local -a instance_ids=() target_groups=()
  [[ "$MODE" == failback ]] || { echo '--release-quarantine requires --failback.' >&2; return 2; }
  verify_restored_fence_for_release \
    || { echo 'Restored fence is unconfirmed, mismatched, or drifted; no source release changes made.' >&2; return 2; }
  [[ -f "$LEDGER/$RUN_ID/failback.json" ]] \
    && jq -e --arg run "$RUN_ID" '.runId==$run and .operation=="failback" and .status=="complete"' \
      "$LEDGER/$RUN_ID/failback.json" >/dev/null \
    || { echo 'Complete endpoint failback is required before releasing the source quarantine.' >&2; return 2; }
  [[ -f "$original_record" ]] \
    || { echo 'No source quarantine journal exists for this run.' >&2; return 2; }
  jq -e --arg run "$RUN_ID" --arg account "$ACCOUNT" --arg region "$REGION" \
    '.runId==$run and .account==$account and .region==$region and (.status=="attached" or .status=="released")' \
    "$original_record" >/dev/null || { echo 'Source quarantine journal is incomplete or mismatched.' >&2; return 2; }
  record_status="$(jq -er '.status' "$original_record")"
  source_primary="$(jq -er '.activePrimary' "$original_record")"
  source_replica="$(jq -r '.activeReplica // empty' "$original_record")"
  source_group="$(jq -er '.quarantineSecurityGroup' "$original_record")"
  [[ "$source_group" != "$QUARANTINE_SG" ]] \
    || { echo 'Source and restored quarantine SGs must be distinct.' >&2; return 2; }
  primary_groups="$(jq -ce '.previousPrimarySecurityGroups|select(length>0)' "$original_record")"
  replica_groups="$(jq -ce '.previousReplicaSecurityGroups' "$original_record")"
  [[ "$source_primary" == "$RETURN_PRIMARY" && "$source_replica" == "$RETURN_REPLICA" ]] \
    || { echo 'Saved source DB IDs do not match this failback run.' >&2; return 2; }
  source_vpc="$(inspect_db "$source_primary" | jq -er '.DBSubnetGroup.VpcId')" \
    || { echo 'Saved source primary has no VPC ID.' >&2; return 2; }
  instance_ids=("$source_primary")
  [[ -z "$source_replica" ]] || instance_ids+=("$source_replica")
  for instance_id in "${instance_ids[@]}"; do
    if [[ "$instance_id" == "$source_primary" ]]; then
      target_groups=()
      while IFS= read -r group_id; do target_groups+=("$group_id"); done < <(jq -r '.[]' <<< "$primary_groups")
    else
      target_groups=()
      while IFS= read -r group_id; do target_groups+=("$group_id"); done < <(jq -r '.[]' <<< "$replica_groups")
    fi
    current_groups="$(group_ids_for_db "$instance_id")"
    expected_groups="$(printf '%s\n' "${target_groups[@]}" | jq -R . | jq -s .)"
    if ! jq -e --arg sg "$source_group" 'length==1 and .[0]==$sg' <<< "$current_groups" >/dev/null; then
      jq -e --argjson expected "$expected_groups" 'sort == ($expected|sort)' <<< "$current_groups" >/dev/null \
        || { echo "Source DB $instance_id has an unexpected SG set; refusing to overwrite it." >&2; return 2; }
    fi
  done
  group_json="$(aws --profile "$PROFILE" --region "$REGION" --no-cli-pager ec2 describe-security-groups \
    --filters "Name=group-id,Values=$source_group" --output json)" || return 2
  group_count="$(jq -er '.SecurityGroups|length' <<< "$group_json")"
  [[ "$group_count" == 0 || "$group_count" == 1 ]] || { echo 'Quarantine SG lookup returned an unexpected result.' >&2; return 2; }
  if [[ "$record_status" == attached ]]; then
    printf 'Restore the saved pre-drill SG sets on the source pair, then delete the temporary SG %s.\n' "$source_group"
    release_approval=''
    bb3_prompt_token_read release_approval 'Type ' RELEASE-SOURCE-QUARANTINE ' to continue: '
    [[ "$release_approval" == RELEASE-SOURCE-QUARANTINE ]] || { echo 'No SG changes made.' >&2; return 2; }
  fi
  if [[ "$group_count" == 1 ]]; then
    verify_quarantine_group "$source_group" "$source_vpc" \
      || { echo 'Saved quarantine SG has changed or has ingress rules.' >&2; return 2; }
  fi
  for instance_id in "${instance_ids[@]}"; do
    if [[ "$instance_id" == "$source_primary" ]]; then
      target_groups=()
      while IFS= read -r group_id; do target_groups+=("$group_id"); done < <(jq -r '.[]' <<< "$primary_groups")
    else
      target_groups=()
      while IFS= read -r group_id; do target_groups+=("$group_id"); done < <(jq -r '.[]' <<< "$replica_groups")
    fi
    current_groups="$(group_ids_for_db "$instance_id")"
    expected_groups="$(printf '%s\n' "${target_groups[@]}" | jq -R . | jq -s .)"
    if jq -e --arg sg "$source_group" 'length==1 and .[0]==$sg' <<< "$current_groups" >/dev/null; then
      aws --profile "$PROFILE" --region "$REGION" --no-cli-pager rds modify-db-instance \
        --db-instance-identifier "$instance_id" --vpc-security-group-ids "${target_groups[@]}" \
        --apply-immediately >/dev/null
      bb3_wait 'Waiting for original DB availability after SG release' aws --profile "$PROFILE" --region "$REGION" --no-cli-pager rds wait db-instance-available \
        --db-instance-identifier "$instance_id"
    fi
    wait_for_saved_security_groups "$instance_id" "$expected_groups" || return 2
  done
  for instance_id in "${instance_ids[@]}"; do
    current_groups="$(group_ids_for_db "$instance_id")"
    jq -e --arg sg "$source_group" 'index($sg)==null' <<< "$current_groups" >/dev/null \
      || { echo 'Quarantine SG remains attached; refusing to delete it.' >&2; return 2; }
  done
  if [[ "$group_count" == 1 ]]; then
    aws --profile "$PROFILE" --region "$REGION" --no-cli-pager ec2 delete-security-group \
      --group-id "$source_group" >/dev/null
    group_json="$(aws --profile "$PROFILE" --region "$REGION" --no-cli-pager ec2 describe-security-groups \
      --filters "Name=group-id,Values=$source_group" --output json)" || return 2
    [[ "$(jq -er '.SecurityGroups|length' <<< "$group_json")" == 0 ]] \
      || { echo 'Temporary quarantine SG still exists; release is incomplete.' >&2; return 2; }
  fi
  jq '.status="released" | .releasedAt=(now|todateiso8601)' "$original_record" > "$original_record.tmp"
  chmod 600 "$original_record.tmp"
  mv "$original_record.tmp" "$original_record"
  printf 'Source SG sets restored and temporary quarantine SG deleted.\n'
}

if [[ "$RELEASE_QUARANTINE" == true ]]; then
  release_source_quarantine
  exit 0
fi

ACTIVE_PRIMARY_JSON="$(inspect_db "$ACTIVE_PRIMARY")"
RETURN_PRIMARY_JSON="$(inspect_db "$RETURN_PRIMARY")"
ACTIVE_ATTACHED_REPLICAS="$(jq -er '(.ReadReplicaDBInstanceIdentifiers // []) | length' <<< "$ACTIVE_PRIMARY_JSON")"
ACTIVE_IS_REPLICA="$(jq -r '.ReadReplicaSourceDBInstanceIdentifier // empty' <<< "$ACTIVE_PRIMARY_JSON")"
ACTIVE_STATUS="$(jq -r '.DBInstanceStatus' <<< "$ACTIVE_PRIMARY_JSON")"
ACTIVE_STANDALONE=false
if [[ "$ACTIVE_ATTACHED_REPLICAS" == 0 && -z "$ACTIVE_IS_REPLICA" ]]; then
  ACTIVE_STANDALONE=true
fi
ACTIVE_ALREADY_STOPPED=false
if [[ "$MODE" == failback && "$ACTIVE_STATUS" == stopped && "$ACTIVE_STANDALONE" == true ]]; then
  ACTIVE_ALREADY_STOPPED=true
elif [[ "$ACTIVE_STATUS" != available ]]; then
  echo 'Active primary must be available, or already stopped as a standalone primary for failback.' >&2
  exit 2
fi
if [[ -n "$ACTIVE_REPLICA" ]]; then
  ACTIVE_REPLICA_JSON="$(inspect_db "$ACTIVE_REPLICA")"
  jq -e --arg replica "$ACTIVE_REPLICA" '(.ReadReplicaDBInstanceIdentifiers // [] | index($replica) != null)' \
    <<< "$ACTIVE_PRIMARY_JSON" >/dev/null || { echo 'Active primary does not own the selected replica.' >&2; exit 2; }
  jq -e --arg primary "$ACTIVE_PRIMARY" '.ReadReplicaSourceDBInstanceIdentifier == $primary' \
    <<< "$ACTIVE_REPLICA_JSON" >/dev/null || { echo 'Active replica belongs to a different primary.' >&2; exit 2; }
elif [[ "$ACTIVE_ATTACHED_REPLICAS" -gt 0 ]]; then
  echo 'Active primary has attached replicas, but no replica ID was supplied. Stop is prohibited.' >&2
  exit 2
fi
RETURN_STATUS="$(jq -r '.DBInstanceStatus' <<< "$RETURN_PRIMARY_JSON")"
RETURN_WAS_STOPPED=false
if [[ "$MODE" == failback && "$RETURN_STATUS" == stopped ]]; then
  RETURN_ATTACHED="$(jq -er '(.ReadReplicaDBInstanceIdentifiers // []) | length' <<< "$RETURN_PRIMARY_JSON")"
  RETURN_SOURCE="$(jq -r '.ReadReplicaSourceDBInstanceIdentifier // empty' <<< "$RETURN_PRIMARY_JSON")"
  [[ "$RETURN_ATTACHED" == 0 && -z "$RETURN_SOURCE" ]] \
    || { echo 'Stopped failback target is not a standalone primary; refusing to start.' >&2; exit 2; }
  RETURN_WAS_STOPPED=true
fi
[[ "$RETURN_STATUS" == available || "$RETURN_WAS_STOPPED" == true ]] \
  || { echo 'Destination primary must be available before fencing.' >&2; exit 2; }
if [[ -n "$RETURN_REPLICA" ]]; then
  RETURN_REPLICA_JSON="$(inspect_db "$RETURN_REPLICA")"
  jq -e --arg replica "$RETURN_REPLICA" '(.ReadReplicaDBInstanceIdentifiers // [] | index($replica) != null)' \
    <<< "$RETURN_PRIMARY_JSON" >/dev/null || { echo 'Destination primary does not own the selected replica.' >&2; exit 2; }
  jq -e --arg primary "$RETURN_PRIMARY" '.ReadReplicaSourceDBInstanceIdentifier == $primary' \
    <<< "$RETURN_REPLICA_JSON" >/dev/null || { echo 'Destination replica belongs to a different primary.' >&2; exit 2; }
elif [[ "$RETURN_WAS_STOPPED" != true && "$(jq -er '(.ReadReplicaDBInstanceIdentifiers // []) | length' <<< "$RETURN_PRIMARY_JSON")" -gt 0 ]]; then
  echo 'Destination primary has attached replicas, but no replica ID was supplied.' >&2
  exit 2
fi

printf 'Active primary: %s\n' "$(jq -er '.Endpoint.Address' <<< "$ACTIVE_PRIMARY_JSON")"
if [[ -n "$ACTIVE_REPLICA" ]]; then
  printf 'Active replica: %s\n' "$(jq -er '.Endpoint.Address' <<< "$ACTIVE_REPLICA_JSON")"
else
  printf 'Active replica: none selected\n'
fi
printf 'Return primary: %s\n' "$(jq -er '.Endpoint.Address' <<< "$RETURN_PRIMARY_JSON")"
if [[ -n "$RETURN_REPLICA" ]]; then
  printf 'Return replica: %s\n' "$(jq -er '.Endpoint.Address' <<< "$RETURN_REPLICA_JSON")"
else
  printf 'Return replica: none selected\n'
fi
  APP_OWNER_INPUT=''
  bb3_prompt_read APP_OWNER_INPUT "App owner name [${APP_OWNER:-required}]: "
  APP_OWNER="${APP_OWNER_INPUT:-$APP_OWNER}"
[[ -n "$APP_OWNER" ]] || { echo 'App owner is required.' >&2; exit 2; }

FENCE_METHOD=none
FENCE_VERIFIED=false
RDS_STOP_CONFIRMED=false
if [[ "$MODE" != failback ]]; then
  [[ -f "$NETWORK_RECORD" ]] \
    || { echo 'P0 quarantine record is required; no source mutation is made in P3-S01.' >&2; exit 2; }
  jq -e --arg run "$RUN_ID" --arg account "$ACCOUNT" --arg region "$REGION" \
    --arg primary "$ACTIVE_PRIMARY" --arg replica "$ACTIVE_REPLICA" \
    '.runId==$run and .account==$account and .region==$region and .activePrimary==$primary and
     (.activeReplica // "")==$replica and .status=="attached"' \
    "$NETWORK_RECORD" >/dev/null \
    || { echo 'P0 quarantine record is not attached for this source pair.' >&2; exit 2; }
  QUARANTINE_SG="$(jq -er '.quarantineSecurityGroup' "$NETWORK_RECORD")"
  vpc_id="$(jq -er '.DBSubnetGroup.VpcId' <<< "$ACTIVE_PRIMARY_JSON")"
  verify_quarantine_group "$QUARANTINE_SG" "$vpc_id" \
    || { echo 'P0 quarantine SG is missing, changed, or has ingress rules.' >&2; exit 2; }
  for instance_id in "$ACTIVE_PRIMARY" "$ACTIVE_REPLICA"; do
    [[ -n "$instance_id" ]] || continue
    current_groups="$(group_ids_for_db "$instance_id")"
    jq -e --arg sg "$QUARANTINE_SG" 'length==1 and .[0]==$sg' <<< "$current_groups" >/dev/null \
      || { echo "P0 quarantine SG is not the only attached SG on $instance_id." >&2; exit 2; }
  done
  FENCE_METHOD=security-group-no-ingress
  FENCE_VERIFIED=true
  printf 'P0 quarantine verified; P3-S01 will not submit another SG change or stop the source DB.\n'
elif [[ "$ACTIVE_STANDALONE" == true ]]; then
  if [[ "$ACTIVE_ALREADY_STOPPED" == true ]]; then
    printf 'Active standalone primary is already stopped; its fence is confirmed by RDS status.\n'
    FENCE_METHOD=rds-stopped
    FENCE_VERIFIED=true
    RDS_STOP_CONFIRMED=true
    SESSIONS_CLOSED=true
  else
    printf 'AWS confirms this is a standalone primary; temporary RDS stop is permitted.\n'
    bb3_prompt_read FENCE_CHOICE 'Fence choice: 1) Stop standalone primary  2) Network fence: '
    case "$FENCE_CHOICE" in
      1)
        printf 'Pause/drain app writers, readers, workers and scheduled jobs before stopping the DB.\n'
        TOKEN=STOP-OLD-PRIMARY
        [[ "$MODE" != failback ]] || TOKEN=STOP-RESTORED-PRIMARY
        bb3_prompt_token_read STOP_APPROVAL \
          'Confirm app clients are drained and stop the active primary. Type ' "$TOKEN" ': '
        [[ "$STOP_APPROVAL" == "$TOKEN" ]] || { echo 'Stop not approved; no change made.' >&2; exit 2; }
        aws --profile "$PROFILE" --region "$REGION" --no-cli-pager rds stop-db-instance \
          --db-instance-identifier "$ACTIVE_PRIMARY" >/dev/null
        bb3_wait 'Waiting for standalone primary to stop' aws --profile "$PROFILE" --region "$REGION" --no-cli-pager rds wait db-instance-stopped \
          --db-instance-identifier "$ACTIVE_PRIMARY"
        ACTIVE_PRIMARY_JSON="$(inspect_db "$ACTIVE_PRIMARY")"
        [[ "$(jq -r '.DBInstanceStatus' <<< "$ACTIVE_PRIMARY_JSON")" == stopped ]] \
          || { echo 'DB did not reach stopped state. No fence record written.' >&2; exit 2; }
        FENCE_METHOD=rds-stopped
        FENCE_VERIFIED=true
        RDS_STOP_CONFIRMED=true
        SESSIONS_CLOSED=true
        ;;
      2) apply_quarantine_group ;;
      *) echo 'Invalid fence choice.' >&2; exit 2 ;;
    esac
  fi
else
  printf 'RDS stop is prohibited: this primary has a read replica or is itself a replica. No stop request will be sent.\n'
  apply_quarantine_group
fi
if [[ "$FENCE_METHOD" == security-group-no-ingress ]]; then
  bb3_prompt_read SESSION_APPROVAL 'Are all app clients and existing DB sessions closed? [y/N]: '
  [[ "$SESSION_APPROVAL" =~ ^[Yy]$ ]] && SESSIONS_CLOSED=true
  [[ "$SESSIONS_CLOSED" == true ]] \
    || printf 'SG isolation is verified, but session closure is unconfirmed; P3-S02 remains blocked.\n'
fi

if [[ "$MODE" == failback && "$RETURN_WAS_STOPPED" == true ]]; then
  printf 'Active pair is fenced; saved return primary is standalone and stopped.\n'
  bb3_prompt_token_read START_APPROVAL 'Type ' START-RETURN-PRIMARY ' to start the saved original primary: '
  [[ "$START_APPROVAL" == START-RETURN-PRIMARY ]] || { echo 'Start not approved; no start request made.' >&2; exit 2; }
  aws --profile "$PROFILE" --region "$REGION" --no-cli-pager rds start-db-instance \
    --db-instance-identifier "$RETURN_PRIMARY" >/dev/null
  bb3_wait 'Waiting for original standalone primary to start' aws --profile "$PROFILE" --region "$REGION" --no-cli-pager rds wait db-instance-available \
    --db-instance-identifier "$RETURN_PRIMARY"
  RETURN_PRIMARY_JSON="$(inspect_db "$RETURN_PRIMARY")"
  [[ "$(jq -r '.DBInstanceStatus' <<< "$RETURN_PRIMARY_JSON")" == available ]] \
    || { echo 'Return primary did not become available.' >&2; exit 2; }
fi
mkdir -p "$(dirname "$RECORD")"
chmod 700 "$LEDGER" "$(dirname "$RECORD")"
TMP="$(mktemp "$(dirname "$RECORD")/.fence.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
ACTIVE_REPLICA_HOST=''; RETURN_REPLICA_HOST=''
if [[ -n "$ACTIVE_REPLICA" ]]; then
  ACTIVE_REPLICA_HOST="$(jq -er '.Endpoint.Address' <<< "$ACTIVE_REPLICA_JSON")"
fi
if [[ -n "$RETURN_REPLICA" ]]; then
  RETURN_REPLICA_HOST="$(jq -er '.Endpoint.Address' <<< "$RETURN_REPLICA_JSON")"
fi
jq -n \
  --arg run "$RUN_ID" --arg mode "$MODE" --arg owner "$APP_OWNER" \
  --arg active_primary "$ACTIVE_PRIMARY" --arg active_replica "$ACTIVE_REPLICA" \
  --arg return_primary "$RETURN_PRIMARY" --arg return_replica "$RETURN_REPLICA" \
  --arg active_primary_host "$(jq -er '.Endpoint.Address' <<< "$ACTIVE_PRIMARY_JSON")" \
  --arg active_replica_host "$ACTIVE_REPLICA_HOST" \
  --arg return_primary_host "$(jq -er '.Endpoint.Address' <<< "$RETURN_PRIMARY_JSON")" \
  --arg return_replica_host "$RETURN_REPLICA_HOST" \
  --arg account "$ACCOUNT" --arg region "$REGION" \
  --arg fence_method "$FENCE_METHOD" --argjson fence_verified "$FENCE_VERIFIED" --argjson stopped "$RDS_STOP_CONFIRMED" \
  --arg quarantine_sg "$QUARANTINE_SG" --argjson sessions_closed "$SESSIONS_CLOSED" \
  '{runId:$run,mode:$mode,status:"owner-confirmed",account:$account,region:$region,
    appOwner:$owner,activePrimary:$active_primary,activeReplica:$active_replica,
    activePrimaryHost:$active_primary_host,activeReplicaHost:$active_replica_host,
    returnPrimary:$return_primary,returnReplica:$return_replica,
    returnPrimaryHost:$return_primary_host,returnReplicaHost:$return_replica_host,
    fenceMethod:$fence_method,fenceVerified:$fence_verified,rdsStopConfirmed:$stopped,
    quarantineSecurityGroup:(if $quarantine_sg=="" then null else $quarantine_sg end),
    existingSessionsClosed:$sessions_closed,
    networkFenceOwnerConfirmed:false,recordedAt:(now|todateiso8601)}' > "$TMP"
chmod 600 "$TMP"
mv "$TMP" "$RECORD"
trap - EXIT
printf 'Owner fence confirmation recorded: %s\n' "$RECORD"
if [[ "$FENCE_METHOD" == rds-stopped ]]; then
  printf 'RDS waiter confirmed the standalone primary is stopped. No security-group rules were changed.\n'
else
  printf 'Run-scoped quarantine SG is attached and verified. Existing session closure: %s.\n' "$SESSIONS_CLOSED"
fi
