#!/usr/bin/env bash
# sandbox-test.sh — test the DR scripts against YOUR real AWS account + EKS cluster, safely.
#
#   source env/uat.env            # or env/dev.env — PROD IS REFUSED
#   tests/aws/sandbox-test.sh readonly      # phase R: zero changes (guard, env-check, preflight, inventory, DRY_RUN)
#   tests/aws/sandbox-test.sh full          # phase R + W: sandbox restore + cutover + rollback, then cleanup
#
# Phase W creates ONLY throw-away resources and deletes them on exit (trap), even on failure:
#   • RDS instance   <PRIMARY_DB>-drtest-<ts>   restored from the latest automated snapshot   (cost: instance-hours)
#   • Secret         <env>/dr-test/db-<ts>        copy of $SECRET_ID (same credentials)        (force-deleted)
#   • Namespace      dr-test-<ts>                 3 sample apps: 2 Reloader-annotated, 1 not   (deleted)
# It NEVER modifies: $SECRET_ID, the app namespace, $PRIMARY_DB, the replica.
#
# Prerequisites (phase W): ESO store that can read <env>/dr-test/* (DRTEST_STORE_KIND/NAME), Reloader installed,
# the image $DRTEST_IMAGE pullable by the cluster, EKS nodes allowed to reach the restored DB (same SGs as primary).
set -uo pipefail
MODE="${1:-readonly}"
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"; S="$ROOT/automation/scripts"
[[ "${DR_ENV:-}" == "prod" ]] && { echo "REFUSED: sandbox tests never run against prod"; exit 2; }
[[ "${DR_ENV:-}" =~ ^(dev|uat)$ ]] || { echo "source env/dev.env or env/uat.env first"; exit 2; }
# shellcheck source=/dev/null
source "$S/dr-lib.sh"; dr_guard || exit 2

TS="$(date -u +%Y%m%d%H%M)"
APP_SECRET_ID="$SECRET_ID"      # the real app secret: read once, never written
SB_DB="${PRIMARY_DB}-drtest-${TS}"; SB_SECRET_ID="${DR_ENV}/dr-test/db-${TS}"; SB_NS="dr-test-${TS}"; SB_K8S_SECRET="dr-test-db-credentials"
DRTEST_STORE_KIND="${DRTEST_STORE_KIND:-ClusterSecretStore}"; DRTEST_STORE_NAME="${DRTEST_STORE_NAME:-aws-secretsmanager}"
DRTEST_IMAGE="${DRTEST_IMAGE:-postgres:16-alpine}"
REPORT="$HERE/sandbox-report-${DR_ENV}-${TS}.md"; PASSN=0; FAILN=0
printf '# DR sandbox test — %s — %s\n\naccount %s · context %s · caller %s\n\n| Test | Result |\n|---|---|\n' \
  "$DR_ENV" "$TS" "$ACCOUNT_ID" "$EKS_CONTEXT" "$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" sts get-caller-identity --query Arn --output text)" > "$REPORT"
ok()  { PASSN=$((PASSN+1)); echo "✅ $*"; echo "| $* | PASS |" >> "$REPORT"; }
nok() { FAILN=$((FAILN+1)); echo "❌ $*"; echo "| $* | **FAIL** |" >> "$REPORT"; }
chk() { local name="$1"; shift; if "$@" >> "$REPORT.log" 2>&1; then ok "$name"; else nok "$name (see $REPORT.log)"; fi; }

echo "=== Phase R — read-only (no changes)"
chk "dr-env-check S3"                       "$S/dr-env-check.sh" S3
chk "preflight restore"                     "$S/dr-preflight.sh" restore
[[ -n "${REPLICA_DB:-}" ]] && chk "preflight replica" "$S/dr-preflight.sh" replica
chk "inventory of $K8S_SECRET consumers"     "$S/dr-eks-rollout.sh" inventory
chk "list snapshots"                         "$S/dr-restore.sh" list-snapshots "$PRIMARY_DB"
SNAP="$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-snapshots --db-instance-identifier "$PRIMARY_DB" --snapshot-type automated --query 'reverse(sort_by(DBSnapshots,&SnapshotCreateTime))[0].DBSnapshotIdentifier' --output text)"
chk "capture baseline of $PRIMARY_DB (describe + tags + pg_settings)" "$S/dr-restore.sh" capture "$PRIMARY_DB"
chk "plan restore from $SNAP (no change)"     "$S/dr-restore.sh" plan snapshot "$SNAP" "$SB_DB"
chk "strict pinning: aws call without --profile is refused (97)" bash -c "aws sts get-caller-identity; [[ \$? == 97 ]]"   # pin-lint: ok (negative test)
chk "strict pinning: another profile is refused (97)"            bash -c "aws --profile not-$AWS_PROFILE --region $AWS_REGION sts get-caller-identity; [[ \$? == 97 ]]"
chk "strict pinning: kubectl without --context is refused (97)"  bash -c "kubectl get ns; [[ \$? == 97 ]]"   # pin-lint: ok (negative test)
chk "secret consumers check (read-only)"     bash -c "'$S/k8s-secret-consumers.sh' --context '$EKS_CONTEXT' -n '$K8S_NS' -s '$K8S_SECRET' --expect-env '$DR_ENV' list"
chk "guard refuses another env's context"    bash -c "! EKS_CONTEXT=does-not-exist DR_GUARD_OK= bash -c 'source $S/dr-lib.sh && dr_guard' 2>/dev/null"
[[ "$MODE" == "full" ]] || { printf '\nPASS=%s FAIL=%s\n' "$PASSN" "$FAILN" | tee -a "$REPORT"; exit "$FAILN"; }

echo "=== Phase W — sandbox (throw-away resources: $SB_DB, $SB_SECRET_ID, ns/$SB_NS)"
read -r -p "Create billable sandbox resources in account $ACCOUNT_ID ($DR_ENV)? type 'sandbox': " a </dev/tty; [[ "$a" == sandbox ]] || exit 1
cleanup() {
  echo "=== cleanup (always)"
  kubectl --context "$EKS_CONTEXT" delete ns "$SB_NS" --wait=false >/dev/null 2>&1 && echo "ns $SB_NS deleted"
  aws --profile "$AWS_PROFILE" --region "$AWS_REGION" secretsmanager delete-secret --secret-id "$SB_SECRET_ID" --force-delete-without-recovery >/dev/null 2>&1 && echo "secret $SB_SECRET_ID deleted"
  if aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-instances --db-instance-identifier "$SB_DB" >/dev/null 2>&1; then
    aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds modify-db-instance --db-instance-identifier "$SB_DB" --no-deletion-protection --apply-immediately >/dev/null 2>&1; sleep 15
    aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds delete-db-instance --db-instance-identifier "$SB_DB" --skip-final-snapshot --delete-automated-backups >/dev/null 2>&1 && echo "instance $SB_DB deleting"
  fi
  printf '\nPASS=%s FAIL=%s · report %s\n' "$PASSN" "$FAILN" "$REPORT" | tee -a "$REPORT"
}
trap cleanup EXIT
export DR_ID="DR-sandbox-${DR_ENV}-${TS}" DR_ASSUME_YES=1
dr_init S3 >/dev/null || exit 1
export OLD_DB="$PRIMARY_DB" SECRET_ID="$SB_SECRET_ID" K8S_NS="$SB_NS" K8S_SECRET="$SB_K8S_SECRET" K8S_HOST_KEY=POSTGRES_DB_HOST SECRET_ID_RO=

# throw-away secret (copy of the app secret, pointing at the primary like the real one)
aws --profile "$AWS_PROFILE" --region "$AWS_REGION" secretsmanager create-secret --name "$SB_SECRET_ID" --tags Key=purpose,Value=dr-sandbox-test \
  --secret-string "$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" secretsmanager get-secret-value --secret-id "$APP_SECRET_ID" --query SecretString --output text)" >/dev/null \
  && ok "sandbox secret created" || { nok "sandbox secret"; exit 1; }

# sandbox namespace + 3 apps (app-a/app-b annotated, app-c NOT)
python3 - "$HERE/k8s-sandbox.tmpl.yaml" "$ROOT/tests/local/k8s" <<PY | kubectl --context "$EKS_CONTEXT" apply -f - >> "$REPORT.log" 2>&1 && ok "sandbox namespace + 3 apps applied" || nok "sandbox apply"
import sys, glob
t = open(sys.argv[1]).read()
apps = "".join("---\n" + open(f).read() for f in sorted(glob.glob(sys.argv[2] + "/2[0-2]-*.yaml")))
apps = apps.replace("namespace: app", "namespace: $SB_NS").replace("app-db-credentials", "$SB_K8S_SECRET").replace("image: postgres:16-alpine", "image: $DRTEST_IMAGE").replace("sslmode=disable", "sslmode=require")
for k, v in {"__NS__": "$SB_NS", "__SECRET__": "$SB_K8S_SECRET", "__STORE_KIND__": "$DRTEST_STORE_KIND", "__STORE_NAME__": "$DRTEST_STORE_NAME",
             "__REMOTE_KEY__": "$SB_SECRET_ID", "__APPS__": apps}.items():
    t = t.replace(k, v)
print(t)
PY
chk "ExternalSecret synced"   kubectl --context "$EKS_CONTEXT" -n "$SB_NS" wait --for=condition=Ready "externalsecret/$SB_K8S_SECRET" --timeout=180s
chk "sample apps running"     bash -c "kubectl --context $EKS_CONTEXT -n $SB_NS rollout status deploy/app-a --timeout=300s && kubectl --context $EKS_CONTEXT -n $SB_NS rollout status statefulset/app-b --timeout=300s && kubectl --context $EKS_CONTEXT -n $SB_NS rollout status deploy/app-c --timeout=300s"
chk "inventory: app-c flagged reloader=NO" bash -c "'$S/dr-eks-rollout.sh' inventory | grep -q 'deployment/app-c .*reloader=NO'"

T_START=$(date +%s)
chk "restore $SNAP → $SB_DB (all SGs from source)" "$S/dr-restore.sh" snapshot "$SNAP" "$SB_DB"
chk "wait until available"     "$S/dr-restore.sh" wait "$SB_DB"
RESTORE_MIN=$(( ($(date +%s) - T_START) / 60 ))
echo "| **Measured snapshot restore time** | **${RESTORE_MIN} min** (DB $(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-instances --db-instance-identifier "$PRIMARY_DB" --query 'DBInstances[0].AllocatedStorage' --output text) GB allocated) |" >> "$REPORT"
chk "harden → VALIDATED against the baseline" bash -c "'$S/dr-restore.sh' harden '$SB_DB' | tee /dev/stderr | grep -q '→ VALIDATED\$'"
chk "SG count equals source"   bash -c "[[ \$(aws --profile $AWS_PROFILE --region $AWS_REGION rds describe-db-instances --db-instance-identifier $SB_DB --query 'length(DBInstances[0].VpcSecurityGroups)') == \$(aws --profile $AWS_PROFILE --region $AWS_REGION rds describe-db-instances --db-instance-identifier $PRIMARY_DB --query 'length(DBInstances[0].VpcSecurityGroups)') ]]"
dr_set_target "$SB_DB" >/dev/null
chk "password precheck (fix-password if rotated)" bash -c "'$S/dr-secret-cutover.sh' precheck || '$S/dr-secret-cutover.sh' fix-password"
chk "validate-pg: pg_settings sandbox == primary" "$S/dr-restore.sh" validate-pg
chk "cutover sandbox secret (RESTART_UNANNOTATED=false)" env RESTART_UNANNOTATED=false "$S/dr-secret-cutover.sh" apply
RPT="$DR_EVIDENCE_DIR/k8s/reload-report-$SB_K8S_SECRET.txt"
chk "Reloader restarted app-a + app-b"  bash -c "grep -q 'app-a: RELOADED' '$RPT' && grep -q 'app-b: RELOADED' '$RPT'"
chk "app-c NOT restarted (UNANNOTATED → SKIPPED)" grep -q 'app-c: UNANNOTATED → SKIPPED' "$RPT"
chk "stale check: app-c STALE"          bash -c "out=\$('$S/dr-eks-rollout.sh' check); rc=\$?; echo \"\$out\"; [[ \$rc != 0 ]] && grep -qE '^STALE +deployment/app-c' <<<\"\$out\""
chk "restart-stale restarts only app-c" bash -c "'$S/dr-eks-rollout.sh' restart-stale | tee /dev/stderr | grep -q '^restarted=1'"
chk "stale check clean"                 "$S/dr-eks-rollout.sh" check
sleep 40
chk "sandbox apps connected to $SB_DB" bash -c "'$S/dr-verify.sh' connections | tee /dev/stderr | grep -A5 'TARGET' | grep -q app-a"
chk "fence F1 on the SANDBOX instance + un-fence" bash -c "'$S/dr-fence-instance.sh' readonly '$SB_DB' && '$S/dr-fence-instance.sh' restore '$SB_DB'"
chk "rollback (RESTART_UNANNOTATED=true)" env RESTART_UNANNOTATED=true "$S/dr-secret-cutover.sh" rollback
chk "evidence bundle"          "$S/dr-collect-evidence.sh"
exit "$FAILN"
