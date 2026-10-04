#!/usr/bin/env bash
# sandbox-test.sh — test the DR scripts against YOUR real AWS account + EKS cluster, safely, step by step.
#
#   source env/uat.env                                   # or env/dev.env — PROD IS REFUSED
#   tests/aws/sandbox-test.sh readonly                   # phase R: zero changes (guard, checks, baseline, plan, pinning)
#   tests/aws/sandbox-test.sh full                       # phase R + W: sandbox restore + cutover + rollback, then cleanup
#   tests/aws/sandbox-test.sh --list                     # show all steps with their IDs
#   tests/aws/sandbox-test.sh cleanup  (with SB_TS=...)  # delete the throw-away resources of an earlier --keep run
#
# Options:
#   --only R02,R06     run only these steps            --skip R03,W19     skip these steps
#   --from W06         start at this step (all earlier steps are skipped — use with SB_TS to resume a --keep run)
#   --on-fail ask|continue|stop    what to do when a step fails (default: ask on a terminal, else continue/stop for
#                      readonly/full). ask = [r]etry / [s]kip / [a]bort. Whatever you choose, a step whose prerequisite
#                      failed is BLOCKED (never run): e.g. no cutover if restore, harden/validate or the password check failed.
#   -q, --quiet        no live output (only ✅/❌ lines); full output is always in <report>.log
#   --keep             full: keep the sandbox resources at the end (resume later: SB_TS=<ts> ... --from Wnn)
#
# Phase W creates ONLY throw-away resources and deletes them on exit (trap), even on failure (unless --keep):
#   • RDS instance   <PRIMARY_DB>-drtest-<ts>   restored from the latest automated snapshot   (cost: instance-hours)
#   • Namespace      dr-test-<ts>               3 sample apps: 2 Reloader-annotated, 1 not + their DB Secret
#   • SECRET_MODE=k8s: the Secret is a COPY of your app's K8s Secret (read once, never written)
#     SECRET_MODE=eso: Secrets Manager secret <env>/dr-test/db-<ts> (copy of $SECRET_ID) + an ExternalSecret
# It NEVER modifies: your app Secret, the app namespace, $PRIMARY_DB, the replica.
# Prerequisites (phase W): Reloader installed; the image $DRTEST_IMAGE pullable by the cluster; EKS nodes allowed to
# reach the restored DB (same SGs as the primary); eso mode: an ESO store that can read <env>/dr-test/*.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"; S="$ROOT/automation/scripts"

MODE="readonly"; ONLY=""; SKIP=""; FROM=""; ON_FAIL=""; QUIET=0; KEEP=0; LIST=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    readonly|full|cleanup) MODE="$1"; shift ;;
    --only) ONLY=",$2,"; shift 2 ;;
    --skip) SKIP=",$2,"; shift 2 ;;
    --from) FROM="$2"; shift 2 ;;
    --on-fail) ON_FAIL="$2"; shift 2 ;;
    -q|--quiet) QUIET=1; shift ;;
    --keep) KEEP=1; shift ;;
    --list) LIST=1; shift ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1 (see --help)"; exit 2 ;;
  esac
done

# ───────────────────────────── step catalogue (ID | phase | name) ─────────────────────────────
STEPS=(
  "R01|R|environment check (dr-env-check.sh S3)"
  "R02|R|pre-flight restore (backups, snapshots, K8s Secret / ExternalSecret, Reloader)"
  "R03|R|pre-flight replica (status, lag, app login) — only if REPLICA_DB is set"
  "R04|R|inventory: workloads using the app Secret, Reloader annotation yes/no"
  "R05|R|list snapshots + PITR window"
  "R06|R|capture baseline of PRIMARY_DB (describe + tags + pg_settings)"
  "R07|R|plan restore from the latest automated snapshot (prints the request, no change)"
  "R08|R|strict pinning: aws without --profile is refused (97)"
  "R09|R|strict pinning: another profile is refused (97)"
  "R10|R|strict pinning: kubectl without --context is refused (97)"
  "R11|R|guard refuses an unknown kube context"
  "R12|R|secret consumers list (k8s-secret-consumers.sh, read-only)"
  "R13|R|current endpoint per host key + change history (SECRET_MODE=k8s, read-only)"
  "W01|W|sandbox namespace + 3 sample apps applied"
  "W02|W|sandbox DB Secret created (k8s: copy of the app Secret · eso: Secrets Manager copy)"
  "W03|W|sandbox Secret present in the namespace (eso: ExternalSecret Ready)"
  "W04|W|sample apps running"
  "W05|W|inventory: app-c flagged reloader=NO"
  "W06|W|restore latest snapshot → sandbox instance (from the baseline)"
  "W07|W|wait until available (measures the restore time)"
  "W08|W|harden → VALIDATED against the baseline"
  "W09|W|security group count equals the source"
  "W10|W|app password works on the restored DB (fix-password if needed)"
  "W11|W|validate-pg: pg_settings sandbox == primary"
  "W12|W|cutover sandbox Secret → sandbox instance (RESTART_UNANNOTATED=false)"
  "W13|W|Reloader restarted app-a + app-b"
  "W14|W|app-c NOT restarted (UNANNOTATED → SKIPPED)"
  "W15|W|stale check finds app-c"
  "W16|W|restart-stale restarts only app-c"
  "W17|W|stale check clean"
  "W18|W|sandbox apps connected to the sandbox instance"
  "W19|W|fence F1 on the SANDBOX instance + un-fence"
  "W20|W|rollback the sandbox Secret (back to the primary endpoint)"
  "W21|W|change history shows cutover + rollback with IDs (SECRET_MODE=k8s)"
  "W22|W|evidence bundle (collect + upload)"
)
# Dependencies: a step whose prerequisite FAILED (or was skipped after failing) is BLOCKED — never run on a broken base.
# A prerequisite that was simply not selected (--only/--from resume) does not block.
declare -A NEEDS=(
  [W02]=W01 [W03]=W02 [W04]=W03 [W05]=W04 [W07]=W06 [W08]=W07 [W09]=W07 [W10]="W07 W03" [W11]=W10
  [W12]="W04 W08 W10" [W13]=W12 [W14]=W12 [W15]=W12 [W16]=W15 [W17]=W16 [W18]=W12 [W19]=W07 [W20]=W12 [W21]=W20
)
declare -A STATUS=()
if (( LIST )); then printf '%s\n' "${STEPS[@]}" | while IFS='|' read -r i _ n; do printf '%-4s %s%s\n' "$i" "$n" "${NEEDS[$i]:+   (needs ${NEEDS[$i]})}"; done; exit 0; fi

[[ "${DR_ENV:-}" == "prod" ]] && { echo "REFUSED: sandbox tests never run against prod"; exit 2; }
if [[ ! "${DR_ENV:-}" =~ ^(dev|uat)$ ]] && ! [[ "${DR_ENV:-}" == local && "${SANDBOX_ALLOW_LOCAL:-0}" == 1 ]]; then
  echo "source env/dev.env or env/uat.env first"; exit 2; fi
# shellcheck source=/dev/null
source "$S/dr-lib.sh"; dr_guard || exit 2

TS="${SB_TS:-$(date -u +%Y%m%d%H%M)}"
APP_NS="$K8S_NS"; APP_K8S_SECRET="$K8S_SECRET"; APP_SECRET_ID="${SECRET_ID:-}"     # the real app secret: read, never written
SB_DB="${PRIMARY_DB}-drtest-${TS}"; SB_SECRET_ID="${DR_ENV}/dr-test/db-${TS}"; SB_NS="dr-test-${TS}"; SB_K8S_SECRET="dr-test-db-credentials"
DRTEST_STORE_KIND="${DRTEST_STORE_KIND:-ClusterSecretStore}"; DRTEST_STORE_NAME="${DRTEST_STORE_NAME:-aws-secretsmanager}"
DRTEST_IMAGE="${DRTEST_IMAGE:-postgres:16-alpine}"
mkdir -p "$HERE/reports"
REPORT="$HERE/reports/sandbox-report-${DR_ENV}-${TS}.md"; LOG="$REPORT.log"; PASSN=0; FAILN=0; SKIPN=0
[[ -n "$ON_FAIL" ]] || { if [[ -t 0 ]]; then ON_FAIL="ask"; elif [[ "$MODE" == full ]]; then ON_FAIL="stop"; else ON_FAIL="continue"; fi; }
[[ "$ON_FAIL" =~ ^(ask|continue|stop)$ ]] || { echo "--on-fail must be ask|continue|stop"; exit 2; }
SNAP="$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-snapshots --db-instance-identifier "$PRIMARY_DB" --snapshot-type automated \
        --query 'reverse(sort_by(DBSnapshots,&SnapshotCreateTime))[0].DBSnapshotIdentifier' --output text 2>/dev/null)"
[[ -f "$REPORT" ]] || printf '# DR sandbox test — %s — %s\n\naccount %s · context %s · caller %s · SECRET_MODE=%s\n\n| Step | Test | Result | Time |\n|---|---|---|---|\n' \
  "$DR_ENV" "$TS" "$ACCOUNT_ID" "$EKS_CONTEXT" "$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" sts get-caller-identity --query Arn --output text)" "$SECRET_MODE" > "$REPORT"
echo "report: $REPORT   log: $LOG   on-fail: $ON_FAIL   SB_TS=$TS"

# ───────────────────────────── runner ─────────────────────────────
selected() { # <id>
  local id="$1"
  [[ -n "$ONLY" && "$ONLY" != *",$id,"* ]] && return 1
  [[ -n "$SKIP" && "$SKIP" == *",$id,"* ]] && return 1
  [[ -n "$FROM" && "$id" < "$FROM" && "${id:0:1}" == "${FROM:0:1}" ]] && return 1
  [[ -n "$FROM" && "${FROM:0:1}" == W && "${id:0:1}" == R ]] && return 1
  return 0
}
step() { # <id> → runs function s_<id>, live output indented, retry/skip/abort on failure
  local id="$1" name rc t0 el ans
  name="$(printf '%s\n' "${STEPS[@]}" | awk -F'|' -v i="$id" '$1==i{print $3}')"
  if ! selected "$id"; then SKIPN=$((SKIPN+1)); echo "⏭  $id $name (not selected)"; echo "| $id | $name | skipped | |" >> "$REPORT"; return 0; fi
  local d; for d in ${NEEDS[$id]:-}; do
    if [[ "${STATUS[$d]:-}" == FAIL || "${STATUS[$d]:-}" == BLOCKED ]]; then
      STATUS[$id]=BLOCKED; SKIPN=$((SKIPN+1)); echo "⛔ $id $name — BLOCKED: prerequisite $d ${STATUS[$d]}"
      echo "| $id | $name | blocked by $d | |" >> "$REPORT"; return 0; fi
  done
  while :; do
    echo "▶  $id $name"; printf '\n### %s %s (%s)\n' "$id" "$name" "$(date -u +%FT%TZ)" >> "$LOG"
    t0=$(date +%s)
    if (( QUIET )); then ( "s_$id" ) >> "$LOG" 2>&1; rc=$?
    else ( "s_$id" ) 2>&1 | tee -a "$LOG" | sed -u 's/^/   │ /'; rc=${PIPESTATUS[0]}; fi
    el=$(( $(date +%s) - t0 ))
    if (( rc == 3 )); then STATUS[$id]=NA; SKIPN=$((SKIPN+1)); echo "➖ $id $name — N/A (nothing to test, see output)"; echo "| $id | $name | n/a | ${el}s |" >> "$REPORT"; return 0; fi
    if (( rc == 0 )); then STATUS[$id]=PASS; PASSN=$((PASSN+1)); echo "✅ $id $name (${el}s)"; echo "| $id | $name | PASS | ${el}s |" >> "$REPORT"; return 0; fi
    echo "❌ $id $name (rc=$rc, ${el}s) — output above / in $LOG"
    case "$ON_FAIL" in
      continue) break ;;
      stop) FAILN=$((FAILN+1)); echo "| $id | $name | **FAIL** | ${el}s |" >> "$REPORT"; echo "stopping (--on-fail stop)"; exit "$FAILN" ;;
      ask) read -r -p "   [r]etry  [s]kip (count as failed)  [a]bort ? " ans </dev/tty
           case "$ans" in r|R) continue ;; a|A) FAILN=$((FAILN+1)); echo "| $id | $name | **FAIL** (aborted) | ${el}s |" >> "$REPORT"; exit "$FAILN" ;; *) break ;; esac ;;
    esac
  done
  STATUS[$id]=FAIL; FAILN=$((FAILN+1)); echo "| $id | $name | **FAIL** | ${el}s |" >> "$REPORT"
}

# ───────────────────────────── phase R steps (read-only) ─────────────────────────────
s_R01() { "$S/dr-env-check.sh" S3; }
s_R02() { "$S/dr-preflight.sh" restore; }
s_R03() { [[ -n "${REPLICA_DB:-}" ]] || { echo "REPLICA_DB not set — nothing to check"; return 0; }; "$S/dr-preflight.sh" replica; }
s_R04() { "$S/dr-eks-rollout.sh" inventory; }
s_R05() { "$S/dr-restore.sh" list-snapshots "$PRIMARY_DB"; }
s_R06() { "$S/dr-restore.sh" capture "$PRIMARY_DB"; }
s_R07() { [[ -n "$SNAP" && "$SNAP" != None ]] || { echo "no automated snapshot of $PRIMARY_DB"; return 1; }; "$S/dr-restore.sh" plan snapshot "$SNAP" "$SB_DB"; }
s_R08() { aws sts get-caller-identity; [[ $? == 97 ]]; }   # pin-lint: ok (negative test)
s_R09() { aws --profile "not-$AWS_PROFILE" --region "$AWS_REGION" sts get-caller-identity; [[ $? == 97 ]]; }
s_R10() { kubectl get ns; [[ $? == 97 ]]; }                                                                # pin-lint: ok (negative test)
s_R11() { ! EKS_CONTEXT=does-not-exist DR_GUARD_OK='' bash -c "source '$S/dr-lib.sh' && dr_guard"; }
s_R12() { "$S/k8s-secret-consumers.sh" --context "$EKS_CONTEXT" -n "$APP_NS" -s "$APP_K8S_SECRET" --expect-env "$DR_ENV" list; }
s_R13() { [[ "$SECRET_MODE" == k8s ]] || { echo "SECRET_MODE=$SECRET_MODE — no ledger"; return 0; }
          "$S/k8s-secret-endpoint.sh" --context "$EKS_CONTEXT" -n "$APP_NS" -s "$APP_K8S_SECRET" -k "${K8S_HOST_KEY:-DB_HOST}" show
          echo "history:"; "$S/k8s-secret-endpoint.sh" --context "$EKS_CONTEXT" -n "$APP_NS" -s "$APP_K8S_SECRET" -k "${K8S_HOST_KEY:-DB_HOST}" history; }

# ───────────────────────────── phase W steps (throw-away resources) ─────────────────────────────
SB_HOST_KEYS="$(tr ',' '\n' <<<"${K8S_HOST_KEY:-DB_HOST},POSTGRES_DB_HOST" | awk 'NF && !s[$0]++' | paste -sd, -)"   # app keys + sample-app key
sandbox_env() {   # point the DR scripts at the SANDBOX (namespace, Secret) — never at the app
  export OLD_DB="$PRIMARY_DB" K8S_NS="$SB_NS" K8S_SECRET="$SB_K8S_SECRET" SECRET_ID_RO=
  if [[ "$SECRET_MODE" == k8s ]]; then export K8S_HOST_KEY="$SB_HOST_KEYS"; else export SECRET_ID="$SB_SECRET_ID" K8S_HOST_KEY=POSTGRES_DB_HOST; fi
}
s_W01() {
  python3 - "$HERE/k8s-sandbox.tmpl.yaml" "$ROOT/tests/local/k8s" "$SECRET_MODE" <<PY | kubectl --context "$EKS_CONTEXT" apply -f -
import sys, glob
t = open(sys.argv[1]).read()
head, tail = t.split("__APPS__", 1)          # apps are appended after the template documents
if sys.argv[3] == "k8s":   # no ESO: drop the ExternalSecret document, the Secret is created by W02
    head = "\n---\n".join(d for d in head.split("\n---\n") if "kind: ExternalSecret" not in d) + "\n"
t = head + "__APPS__" + tail
apps = "".join("---\n" + open(f).read() for f in sorted(glob.glob(sys.argv[2] + "/2[0-2]-*.yaml")))
apps = (apps.replace("namespace: app", "namespace: $SB_NS").replace("app-db-credentials", "$SB_K8S_SECRET")
            .replace("image: postgres:16-alpine", "image: $DRTEST_IMAGE").replace("sslmode=disable", "sslmode=${DRTEST_PGSSLMODE:-require}"))
for k, v in {"__NS__": "$SB_NS", "__SECRET__": "$SB_K8S_SECRET", "__STORE_KIND__": "$DRTEST_STORE_KIND", "__STORE_NAME__": "$DRTEST_STORE_NAME",
             "__REMOTE_KEY__": "$SB_SECRET_ID", "__APPS__": apps}.items():
    t = t.replace(k, v)
print(t)
PY
  local o; for o in deploy/app-a statefulset/app-b deploy/app-c; do                      # all 3 apps must exist
    kubectl --context "$EKS_CONTEXT" -n "$SB_NS" get "$o" -o name || { echo "missing $o after apply"; return 1; }; done
}
s_W02() {
  if [[ "$SECRET_MODE" == k8s ]]; then
    # copy of the app Secret (all keys) + the generic keys the sample apps read; every host key = the primary's host
    kubectl --context "$EKS_CONTEXT" -n "$APP_NS" get secret "$APP_K8S_SECRET" -o json | jq \
      --arg ns "$SB_NS" --arg name "$SB_K8S_SECRET" --arg hk "${K8S_HOST_KEY:-DB_HOST}" --arg pk "${K8S_PORT_KEY:-}" \
      --arg uk "${K8S_USER_KEY:-POSTGRES_DB_USER}" --arg pwk "${K8S_PASSWORD_KEY:-POSTGRES_DB_PASSWORD}" --arg db "${DB_NAME:-app}" '
      ($hk | split(",")[0]) as $h1 | .data as $d
      | {apiVersion: "v1", kind: "Secret", type: "Opaque",
         metadata: {name: $name, namespace: $ns, labels: {purpose: "dr-sandbox-test"}},
         data: ($d + {POSTGRES_DB_HOST: $d[$h1], POSTGRES_DB_PORT: (if $pk != "" then $d[$pk] else ("5432" | @base64) end),
                      POSTGRES_DB_NAME: ($db | @base64), POSTGRES_DB_USER: $d[$uk], POSTGRES_DB_PASSWORD: $d[$pwk]})}' \
      | kubectl --context "$EKS_CONTEXT" apply -f -
  else
    aws --profile "$AWS_PROFILE" --region "$AWS_REGION" secretsmanager create-secret --name "$SB_SECRET_ID" --tags Key=purpose,Value=dr-sandbox-test \
      --secret-string "$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" secretsmanager get-secret-value --secret-id "$APP_SECRET_ID" --query SecretString --output text)" \
      --query Name --output text
  fi
}
s_W03() {
  if [[ "$SECRET_MODE" == k8s ]]; then kubectl --context "$EKS_CONTEXT" -n "$SB_NS" get secret "$SB_K8S_SECRET" -o json | jq -r '.data | keys | join(" ")'
  else kubectl --context "$EKS_CONTEXT" -n "$SB_NS" wait --for=condition=Ready "externalsecret/$SB_K8S_SECRET" --timeout=180s; fi
}
s_W04() { local o; for o in deploy/app-a statefulset/app-b deploy/app-c; do kubectl --context "$EKS_CONTEXT" -n "$SB_NS" rollout status "$o" --timeout=300s || return 1; done; }
s_W05() { sandbox_env; "$S/dr-eks-rollout.sh" inventory | tee /dev/stderr | grep -q 'deployment/app-c .*reloader=NO'; }
s_W06() { [[ -n "$SNAP" && "$SNAP" != None ]] || { echo "no automated snapshot"; return 1; }; "$S/dr-restore.sh" snapshot "$SNAP" "$SB_DB"; }
s_W07() { local t0; t0=$(date +%s); "$S/dr-restore.sh" wait "$SB_DB" || return 1
          echo "| **Measured snapshot restore time** | **$(( ($(date +%s) - t0) / 60 )) min** (DB $(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-instances --db-instance-identifier "$PRIMARY_DB" --query 'DBInstances[0].AllocatedStorage' --output text) GB allocated) | info | |" >> "$REPORT"; }
s_W08() { "$S/dr-restore.sh" harden "$SB_DB" | tee /dev/stderr | grep -q '→ VALIDATED$'; }
s_W09() { [[ $(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-instances --db-instance-identifier "$SB_DB" --query 'length(DBInstances[0].VpcSecurityGroups)') \
           == $(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-instances --db-instance-identifier "$PRIMARY_DB" --query 'length(DBInstances[0].VpcSecurityGroups)') ]]; }
s_W10() { sandbox_env; dr_set_target "$SB_DB" >/dev/null; "$S/dr-secret-cutover.sh" precheck || "$S/dr-secret-cutover.sh" fix-password; }
s_W11() { sandbox_env; dr_set_target "$SB_DB" >/dev/null; "$S/dr-restore.sh" validate-pg; }
s_W12() { sandbox_env; dr_set_target "$SB_DB" >/dev/null; RESTART_UNANNOTATED=false CUTOVER_ID="${DR_ID}" "$S/dr-secret-cutover.sh" apply; }
RPT() { echo "$DR_EVIDENCE_DIR/k8s/reload-report-$SB_K8S_SECRET.txt"; }
s_W13() { cat "$(RPT)"; grep -q 'app-a: RELOADED' "$(RPT)" && grep -q 'app-b: RELOADED' "$(RPT)"; }
s_W14() { grep -q 'app-c: UNANNOTATED → SKIPPED' "$(RPT)"; }
s_W15() { local out rc; sandbox_env; out="$("$S/dr-eks-rollout.sh" check)"; rc=$?; echo "$out"; [[ $rc != 0 ]] && grep -qE '^STALE +deployment/app-c' <<<"$out"; }
s_W16() { sandbox_env; "$S/dr-eks-rollout.sh" restart-stale | tee /dev/stderr | grep -q '^restarted=1'; }
s_W17() { sandbox_env; "$S/dr-eks-rollout.sh" check; }
s_W18() { local i; sandbox_env; dr_set_target "$SB_DB" >/dev/null
          for i in $(seq 1 12); do "$S/dr-verify.sh" connections | grep -A5 'TARGET' | grep -q app-a && { echo "app-a connected to $SB_DB"; return 0; }; sleep 10; done
          "$S/dr-verify.sh" connections; return 1; }
s_W19() { sandbox_env; "$S/dr-fence-instance.sh" readonly "$SB_DB" && "$S/dr-fence-instance.sh" restore "$SB_DB"; }
s_W20() { sandbox_env; RESTART_UNANNOTATED=true CUTOVER_ID="${DR_ID}-rollback" "$S/dr-secret-cutover.sh" rollback; }
s_W21() { [[ "$SECRET_MODE" == k8s ]] || { echo "eso mode — no ledger"; return 0; }; sandbox_env
          "$S/dr-secret-cutover.sh" history | tee /dev/stderr | grep -q "ROLLBACK  ${DR_ID}-rollback  (ref ${DR_ID})"; }
s_W22() { sandbox_env; "$S/dr-collect-evidence.sh"; }

cleanup() {
  echo "=== cleanup of sandbox resources (SB_TS=$TS)"
  kubectl --context "$EKS_CONTEXT" delete ns "$SB_NS" --wait=false >/dev/null 2>&1 && echo "ns $SB_NS deleted"
  [[ "$SECRET_MODE" == k8s ]] || { aws --profile "$AWS_PROFILE" --region "$AWS_REGION" secretsmanager delete-secret --secret-id "$SB_SECRET_ID" --force-delete-without-recovery >/dev/null 2>&1 && echo "secret $SB_SECRET_ID deleted"; }
  if aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-instances --db-instance-identifier "$SB_DB" >/dev/null 2>&1; then
    aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds modify-db-instance --db-instance-identifier "$SB_DB" --no-deletion-protection --apply-immediately >/dev/null 2>&1; sleep "${CLEANUP_SETTLE_S:-15}"
    aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds delete-db-instance --db-instance-identifier "$SB_DB" --skip-final-snapshot --delete-automated-backups >/dev/null 2>&1 && echo "instance $SB_DB deleting"
  fi
}
finish() {
  if [[ "$MODE" == full ]]; then
    if (( KEEP )); then echo "=== --keep: sandbox kept. Resume: SB_TS=$TS $0 full --from <Wnn> · remove: SB_TS=$TS $0 cleanup"
    else cleanup; fi
  fi
  printf '\nPASS=%s FAIL=%s SKIPPED=%s · report %s\n' "$PASSN" "$FAILN" "$SKIPN" "$REPORT" | tee -a "$REPORT"
}

# ───────────────────────────── main ─────────────────────────────
if [[ "$MODE" == cleanup ]]; then
  [[ -n "${SB_TS:-}" ]] || { echo "cleanup needs SB_TS=<ts of the run> (see the report name)"; exit 2; }
  read -r -p "Delete sandbox resources $SB_DB, ns/$SB_NS in $ACCOUNT_ID ($DR_ENV)? type 'cleanup': " a </dev/tty; [[ "$a" == cleanup ]] || exit 1
  cleanup; exit 0
fi
trap finish EXIT
echo "=== Phase R — read-only (no changes)"
for e in "${STEPS[@]}"; do [[ "${e:4:1}" == R ]] && step "${e:0:3}"; done
[[ "$MODE" == full ]] || exit "$FAILN"

w_selected=0; for e in "${STEPS[@]}"; do [[ "${e:4:1}" == W ]] && selected "${e:0:3}" && w_selected=1; done
(( w_selected )) || exit "$FAILN"
echo "=== Phase W — sandbox (throw-away: $SB_DB, ns/$SB_NS$([[ $SECRET_MODE == eso ]] && echo ", $SB_SECRET_ID"))"
if [[ "$DR_ENV" == local && "${SANDBOX_ALLOW_LOCAL:-0}" == 1 ]]; then echo "(local rehearsal: no confirmation)"
else read -r -p "Create/use billable sandbox resources in account $ACCOUNT_ID ($DR_ENV)? type 'sandbox': " a </dev/tty; [[ "$a" == sandbox ]] || exit 1; fi
export DR_ID="DR-sandbox-${DR_ENV}-${TS}" DR_ASSUME_YES=1
export DR_EVIDENCE_DIR="${DR_EVIDENCE_DIR:-$ROOT/evidence/$DR_ID}"
dr_init S3 >/dev/null || exit 1
for e in "${STEPS[@]}"; do [[ "${e:4:1}" == W ]] && step "${e:0:3}"; done
exit "$FAILN"
