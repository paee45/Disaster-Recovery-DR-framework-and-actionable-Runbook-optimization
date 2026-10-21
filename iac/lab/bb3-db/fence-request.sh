#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
CONFIG="${BB3_SANDBOX_CONFIG:-$ROOT/iac/sandbox.env}"
LEDGER="${BB3_LEDGER_DIR:-$ROOT/evidence/bb3-secret-endpoints}"
BASELINE_STORE="${BB3_RESTORE_BASELINE_DIR:-$HERE/baselines}"
MODE="${1:-}"
[[ $# == 1 && "$MODE" == pre-impact ]] \
  || { echo 'Usage: fence-request.sh pre-impact' >&2; exit 2; }
[[ -f "$CONFIG" ]] || { echo 'Missing ignored iac/sandbox.env.' >&2; exit 2; }
# shellcheck source=/dev/null
source "$CONFIG"
unset AWS_DEFAULT_PROFILE TF_VAR_terrakube_token
PROFILE="${TF_VAR_aws_profile:-}"
REGION="${TF_VAR_region:-}"
ACCOUNT="${TF_VAR_account_id:-}"
RUN_ID="${BB3_DR_ID:-}"
ACTIVE_PRIMARY="${BB3_SOURCE_PRIMARY_ID:-}"
ACTIVE_REPLICA="${BB3_SOURCE_REPLICA_ID:-}"
RETURN_PRIMARY="${BB3_RESTORE_TARGET_PRIMARY_ID:-}"
[[ "$PROFILE" =~ ^(lab_sandbox|pa_aws_sandbox|pa_iam_aws_sandbox)$ \
  && "$REGION" == ap-southeast-1 && "$ACCOUNT" =~ ^[0-9]{12}$ \
  && "${ENV:-}" =~ ^(dev|uat)$ \
  && "$ACTIVE_PRIMARY" =~ ^[A-Za-z][A-Za-z0-9-]*$ && "$RETURN_PRIMARY" =~ ^[A-Za-z][A-Za-z0-9-]*$ ]] \
  || { echo 'Run P0-S01 discovery and P0-S02 baseline capture first.' >&2; exit 2; }
RESET_TIMING=false
if [[ -n "$RUN_ID" && -f "$LEDGER/$RUN_ID/incident.json" ]]; then
  previous_network_record="$LEDGER/$RUN_ID/network-fence.json"
  if [[ ! -e "$previous_network_record" ]] || jq -e '.status=="released"' "$previous_network_record" >/dev/null; then
    printf 'Previous run has no active quarantine; preserving it and allocating a fresh run ID.\n'
    RUN_ID=''
    RESET_TIMING=true
  else
    echo 'Previous incident has an unreleased quarantine journal; resume or complete its approved failback first.' >&2
    exit 2
  fi
fi
if [[ -z "$RUN_ID" ]]; then
  RUN_ID="DR-$(date -u +%Y%m%d-%H%M%S)-${ENV}-BB3-S3"
  temporary="$(mktemp "${CONFIG}.tmp.XXXXXX")"
  if [[ "$RESET_TIMING" == true ]]; then
    awk '$0 !~ /^export BB3_(DR_ID|T0_AT|T0_EVIDENCE_REF|T1_AT|T1_EVIDENCE_REF|SCENARIO)=/' "$CONFIG" > "$temporary"
  else
    awk '$0 !~ /^export BB3_DR_ID=/' "$CONFIG" > "$temporary"
  fi
  printf 'export BB3_DR_ID=%q\n' "$RUN_ID" >> "$temporary"
  chmod 600 "$temporary"
  mv "$temporary" "$CONFIG"
fi
[[ "$RUN_ID" =~ ^DR-[A-Za-z0-9_-]{1,120}$ ]] || { echo 'Saved BB3 run ID is invalid.' >&2; exit 2; }
[[ -z "${AWS_ACCESS_KEY_ID:-}${AWS_SECRET_ACCESS_KEY:-}${AWS_SESSION_TOKEN:-}" ]] \
  || { echo 'Unset exported AWS credentials.' >&2; exit 2; }
CALLER="$(aws --profile "$PROFILE" --region "$REGION" --no-cli-pager sts get-caller-identity --query Account --output text)"
[[ "$CALLER" == "$ACCOUNT" ]] || { echo 'AWS caller does not match the configured sandbox.' >&2; exit 2; }
[[ -t 0 ]] || { echo 'Fence request requires an interactive terminal.' >&2; exit 2; }
git -C "$ROOT" check-ignore -q "$CONFIG" \
  || { echo 'sandbox.env must be Git-ignored.' >&2; exit 2; }
git -C "$ROOT" check-ignore -q "$LEDGER/check.json" \
  || { echo 'Fence records must be Git-ignored.' >&2; exit 2; }
[[ ! -e "$LEDGER/$RUN_ID/incident.json" ]] \
  || { echo 'This run ID is already declared; use its saved run instead.' >&2; exit 2; }

temporary="$(mktemp "${CONFIG}.tmp.XXXXXX")"
awk '$0 !~ /^export BB3_DR_ID=/' "$CONFIG" > "$temporary"
printf 'export BB3_DR_ID=%q\n' "$RUN_ID" >> "$temporary"
chmod 600 "$temporary"
mv "$temporary" "$CONFIG"

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else echo 'SHA-256 tool is required to verify the baseline.' >&2; return 2
  fi
}
verify_baseline_member() {
  local relative="$1" expected actual
  expected="$(jq -er --arg path "$relative" '.files[] | select(.path==$path) | .sha256' "$CAPTURE_DIR/manifest.json")" \
    || { echo "Baseline manifest is missing $relative." >&2; return 1; }
  [[ "$expected" =~ ^[a-fA-F0-9]{64}$ && -f "$CAPTURE_DIR/$relative" ]] || return 1
  actual="$(hash_file "$CAPTURE_DIR/$relative")" || return 1
  [[ "$actual" == "$expected" ]]
}

LATEST="$BASELINE_STORE/latest.json"
[[ -f "$LATEST" ]] || { echo 'Capture the original DB baseline before requesting a fence.' >&2; exit 2; }
CAPTURE_NAME="$(jq -er '.directory | select(test("^[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9]+$"))' "$LATEST")" \
  || { echo 'Latest baseline reference is invalid.' >&2; exit 2; }
CAPTURE_DIR="$BASELINE_STORE/$CAPTURE_NAME"
[[ "$(jq -r '.status' "$LATEST")" == complete && -f "$CAPTURE_DIR/manifest.json" ]] \
  || { echo 'Latest baseline capture is incomplete.' >&2; exit 2; }
cmp -s "$LATEST" "$CAPTURE_DIR/capture.json" || { echo 'Latest baseline reference does not match its capture.' >&2; exit 2; }
verify_baseline_member capture.json || exit 2
verify_baseline_member primary/baseline.json || exit 2
PRIMARY_BASELINE="$(jq -c . "$CAPTURE_DIR/primary/baseline.json")"
[[ "$(jq -r '.source' <<< "$PRIMARY_BASELINE")" == "$ACTIVE_PRIMARY" \
  && "$(jq -r '.account' <<< "$PRIMARY_BASELINE")" == "$ACCOUNT" \
  && "$(jq -r '.region' <<< "$PRIMARY_BASELINE")" == "$REGION" ]] \
  || { echo 'Captured primary baseline does not match this run/account/region.' >&2; exit 2; }
PREVIOUS_PRIMARY_GROUPS="$(jq -ce '[.instance.VpcSecurityGroups[].VpcSecurityGroupId] | select(length>0)' <<< "$PRIMARY_BASELINE")" || exit 2
PREVIOUS_REPLICA_GROUPS='[]'
if [[ -n "$ACTIVE_REPLICA" ]]; then
  [[ "$(jq -r '.replica // ""' "$LATEST")" == 'replica/baseline.json' ]] \
    || { echo 'Latest capture does not contain the selected source replica.' >&2; exit 2; }
  verify_baseline_member replica/baseline.json || exit 2
  REPLICA_BASELINE="$(jq -c . "$CAPTURE_DIR/replica/baseline.json")"
  [[ "$(jq -r '.source' <<< "$REPLICA_BASELINE")" == "$ACTIVE_REPLICA" ]] \
    || { echo 'Captured replica baseline does not match the selected source replica.' >&2; exit 2; }
  PREVIOUS_REPLICA_GROUPS="$(jq -ce '[.instance.VpcSecurityGroups[].VpcSecurityGroupId] | select(length>0)' <<< "$REPLICA_BASELINE")" || exit 2
fi

NETWORK_RECORD="$LEDGER/$RUN_ID/network-fence.json"
inspect_db() {
  aws --profile "$PROFILE" --region "$REGION" --no-cli-pager rds describe-db-instances \
    --db-instance-identifier "$1" --query 'DBInstances[0]' --output json
}
group_ids_for_db() {
  aws --profile "$PROFILE" --region "$REGION" --no-cli-pager rds describe-db-instances \
    --db-instance-identifier "$1" --query 'DBInstances[0].VpcSecurityGroups[].VpcSecurityGroupId' --output json
}
verify_quarantine_group() {
  local response
  response="$(aws --profile "$PROFILE" --region "$REGION" --no-cli-pager ec2 describe-security-groups --group-ids "$1" --output json)" || return 1
  jq -e --arg id "$1" --arg run "$RUN_ID" --arg vpc "$2" '
    (.SecurityGroups|length)==1 and .SecurityGroups[0].GroupId==$id and
    .SecurityGroups[0].VpcId==$vpc and
    any(.SecurityGroups[0].Tags[]?; .Key=="dr-run" and .Value==$run) and
    any(.SecurityGroups[0].Tags[]?; .Key=="dr-role" and .Value=="quarantine") and
    ((.SecurityGroups[0].IpPermissions // [])|length)==0
  ' <<< "$response" >/dev/null
}

PRIMARY_JSON="$(inspect_db "$ACTIVE_PRIMARY")"
[[ "$(jq -r '.DBInstanceStatus' <<< "$PRIMARY_JSON")" == available ]] \
  || { echo 'Source primary must be available before submitting the early fence.' >&2; exit 2; }
VPC_ID="$(jq -er '.DBSubnetGroup.VpcId' <<< "$PRIMARY_JSON")" \
  || { echo 'Source primary has no VPC ID.' >&2; exit 2; }
REPLICA_JSON=''
if [[ -n "$ACTIVE_REPLICA" ]]; then
  REPLICA_JSON="$(inspect_db "$ACTIVE_REPLICA")"
  [[ "$(jq -r '.DBInstanceStatus' <<< "$REPLICA_JSON")" == available \
    && "$(jq -r '.ReadReplicaSourceDBInstanceIdentifier | split(":") | last' <<< "$REPLICA_JSON")" == "$ACTIVE_PRIMARY" \
    && "$(jq -r '.DBSubnetGroup.VpcId' <<< "$REPLICA_JSON")" == "$VPC_ID" ]] \
    || { echo 'Source replica must be available, attached to the source primary, and in the same VPC.' >&2; exit 2; }
fi

INSTANCE_IDS=("$ACTIVE_PRIMARY")
[[ -z "$ACTIVE_REPLICA" ]] || INSTANCE_IDS+=("$ACTIVE_REPLICA")
if [[ -f "$NETWORK_RECORD" ]]; then
  jq -e --arg run "$RUN_ID" --arg account "$ACCOUNT" --arg region "$REGION" \
    --arg primary "$ACTIVE_PRIMARY" --arg replica "$ACTIVE_REPLICA" \
    '.runId==$run and .account==$account and .region==$region and .activePrimary==$primary and
     (.activeReplica // "")==$replica and (.status=="prepared" or .status=="submitted" or .status=="attached")' \
    "$NETWORK_RECORD" >/dev/null \
    || { echo 'An existing fence record does not match this incident or is not resumable.' >&2; exit 2; }
  QUARANTINE_SG="$(jq -er '.quarantineSecurityGroup' "$NETWORK_RECORD")"
else
  OLD_PRIMARY_GROUPS="$(group_ids_for_db "$ACTIVE_PRIMARY")"
  OLD_REPLICA_GROUPS='[]'
  [[ -z "$ACTIVE_REPLICA" ]] || OLD_REPLICA_GROUPS="$(group_ids_for_db "$ACTIVE_REPLICA")"
  jq -e --argjson baseline "$PREVIOUS_PRIMARY_GROUPS" \
    'sort == ($baseline|sort)' <<< "$OLD_PRIMARY_GROUPS" >/dev/null \
    || { echo 'Live primary SGs differ from the captured pre-quarantine baseline; refusing the change.' >&2; exit 2; }
  if [[ -n "$ACTIVE_REPLICA" ]]; then
    jq -e --argjson baseline "$PREVIOUS_REPLICA_GROUPS" \
      'sort == ($baseline|sort)' <<< "$OLD_REPLICA_GROUPS" >/dev/null \
      || { echo 'Live replica SGs differ from the captured pre-quarantine baseline; refusing the change.' >&2; exit 2; }
  fi
  printf 'Current source primary %s SGs: %s\n' "$ACTIVE_PRIMARY" "$(jq -r 'join(", ")' <<< "$OLD_PRIMARY_GROUPS")"
  if [[ -n "$ACTIVE_REPLICA" ]]; then
    printf 'Current source replica %s SGs: %s\n' "$ACTIVE_REPLICA" "$(jq -r 'join(", ")' <<< "$OLD_REPLICA_GROUPS")"
  fi
  printf 'Keep the app and health monitor active to observe the connection failure. Existing sessions may continue.\n'
  read -r -p 'Create quarantine SG and submit pair changes without waiting? [y/N]: ' APPROVE
  [[ "$APPROVE" =~ ^[Yy]$ ]] || { echo 'Fence request cancelled; no SG created.' >&2; exit 2; }
  GROUP_NAME="dr-bb3-${ENV}-quarantine-${RUN_ID//_/-}"
  QUARANTINE_SG="$(aws --profile "$PROFILE" --region "$REGION" --no-cli-pager ec2 create-security-group \
    --group-name "$GROUP_NAME" --description "Temporary BB3 DR quarantine for $RUN_ID" --vpc-id "$VPC_ID" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$GROUP_NAME},{Key=dr-run,Value=$RUN_ID},{Key=dr-role,Value=quarantine}]" \
    --query GroupId --output text)" || exit 2
  [[ "$QUARANTINE_SG" =~ ^sg-[a-f0-9]+$ ]] || { echo 'AWS returned an invalid quarantine SG ID.' >&2; exit 2; }
  verify_quarantine_group "$QUARANTINE_SG" "$VPC_ID" \
    || { echo 'New quarantine SG failed same-VPC/tag/no-ingress verification.' >&2; exit 2; }
  mkdir -p "$(dirname "$NETWORK_RECORD")"
  chmod 700 "$LEDGER" "$(dirname "$NETWORK_RECORD")"
  jq -n --arg run "$RUN_ID" --arg env "$ENV" --arg account "$ACCOUNT" --arg region "$REGION" \
    --arg primary "$ACTIVE_PRIMARY" --arg replica "$ACTIVE_REPLICA" --arg sg "$QUARANTINE_SG" \
    --argjson primary_groups "$PREVIOUS_PRIMARY_GROUPS" --argjson replica_groups "$PREVIOUS_REPLICA_GROUPS" \
    '{runId:$run,mode:"cutover",environment:$env,account:$account,region:$region,activePrimary:$primary,
      activeReplica:(if $replica=="" then null else $replica end),quarantineSecurityGroup:$sg,
      previousPrimarySecurityGroups:$primary_groups,previousReplicaSecurityGroups:$replica_groups,
      submittedInstances:[],status:"prepared",recordedAt:(now|todateiso8601)}' > "$NETWORK_RECORD"
  chmod 600 "$NETWORK_RECORD"
fi

verify_quarantine_group "$QUARANTINE_SG" "$VPC_ID" \
  || { echo 'Journaled quarantine SG is missing or unsafe.' >&2; exit 2; }
for instance_id in "${INSTANCE_IDS[@]}"; do
  current_groups="$(group_ids_for_db "$instance_id")"
  if ! jq -e --arg sg "$QUARANTINE_SG" 'length==1 and .[0]==$sg' <<< "$current_groups" >/dev/null; then
    status="$(aws --profile "$PROFILE" --region "$REGION" --no-cli-pager rds describe-db-instances \
      --db-instance-identifier "$instance_id" --query 'DBInstances[0].DBInstanceStatus' --output text)"
    [[ "$status" == available ]] || { echo "$instance_id is $status; quarantine attachment cannot be submitted." >&2; exit 2; }
    aws --profile "$PROFILE" --region "$REGION" --no-cli-pager rds modify-db-instance \
      --db-instance-identifier "$instance_id" --vpc-security-group-ids "$QUARANTINE_SG" \
      --apply-immediately >/dev/null || exit 2
    jq --arg id "$instance_id" --arg at "$(date -u +%FT%TZ)" \
      '.submittedInstances += [$id] | .status="submitted" | .lastSubmittedAt=$at' \
      "$NETWORK_RECORD" > "$NETWORK_RECORD.tmp"
    chmod 600 "$NETWORK_RECORD.tmp"
    mv "$NETWORK_RECORD.tmp" "$NETWORK_RECORD"
  fi
done
for instance_id in "${INSTANCE_IDS[@]}"; do
  aws --profile "$PROFILE" --region "$REGION" --no-cli-pager rds wait db-instance-available \
    --db-instance-identifier "$instance_id"
  current_groups="$(group_ids_for_db "$instance_id")"
  jq -e --arg sg "$QUARANTINE_SG" 'length==1 and .[0]==$sg' <<< "$current_groups" >/dev/null \
    || { echo "Quarantine SG is not active on $instance_id; no T0 may be recorded." >&2; exit 2; }
done
read -r -p 'App/monitor/logs evidence reference for observed DB connection failures: ' IMPACT_EVIDENCE_REF
[[ -n "$IMPACT_EVIDENCE_REF" ]] || { echo 'App failure evidence reference is required.' >&2; exit 2; }
jq --arg ref "$IMPACT_EVIDENCE_REF" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '.status="attached" | .attachedAt=$at | .impactEvidenceRef=$ref' \
  "$NETWORK_RECORD" > "$NETWORK_RECORD.tmp"
chmod 600 "$NETWORK_RECORD.tmp"
mv "$NETWORK_RECORD.tmp" "$NETWORK_RECORD"
SAVED_IMPACT_REF="$(jq -r '.impactEvidenceRef // empty' "$NETWORK_RECORD")"
if [[ "$(jq -r '.status' "$NETWORK_RECORD")" != attached || ${#SAVED_IMPACT_REF} -lt 3 \
  || "$SAVED_IMPACT_REF" =~ ^([Yy]|[Yy][Ee][Ss]|[Nn]|[Nn][Oo])$ ]]; then
  read -r -p 'App/monitor/logs evidence reference for observed DB connection failures: ' IMPACT_EVIDENCE_REF
  [[ ${#IMPACT_EVIDENCE_REF} -ge 3 && ! "$IMPACT_EVIDENCE_REF" =~ ^([Yy]|[Yy][Ee][Ss]|[Nn]|[Nn][Oo])$ ]] \
    || { echo 'Enter a meaningful app/monitor evidence reference, not a yes/no response.' >&2; exit 2; }
   jq --arg ref "$IMPACT_EVIDENCE_REF" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     '.status="attached" | .attachedAt=$at | .impactEvidenceRef=$ref' \
     "$NETWORK_RECORD" > "$NETWORK_RECORD.tmp"
   chmod 600 "$NETWORK_RECORD.tmp"
   mv "$NETWORK_RECORD.tmp" "$NETWORK_RECORD"
 else
  IMPACT_EVIDENCE_REF="$SAVED_IMPACT_REF"
 fi
 temporary="$(mktemp "${CONFIG}.tmp.XXXXXX")"
 awk '$0 !~ /^export BB3_T0_EVIDENCE_REF=/' "$CONFIG" > "$temporary"
 printf 'export BB3_T0_EVIDENCE_REF=%q\n' "$IMPACT_EVIDENCE_REF" >> "$temporary"
 chmod 600 "$temporary"
 mv "$temporary" "$CONFIG"
printf 'P0 quarantine verified on the source pair using %s; app failure evidence recorded. P1-S01-1 can now record T0.\n' "$QUARANTINE_SG"