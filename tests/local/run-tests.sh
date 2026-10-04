#!/usr/bin/env bash
# run-tests.sh — end-to-end tests of every DR script against the local test bed (tests/local/up.sh).
# Produces tests/local/.state/test-report.md. Exit code = number of failed tests.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"; STATE="$HERE/.state"
S="$ROOT/automation/scripts"; LOGS="$STATE/logs"; mkdir -p "$LOGS"; cd "$HERE" || exit 1
# shellcheck source=/dev/null
source "$STATE/local.env"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_ENDPOINT_URL PGPASSWORD
DR_ID="DR-localtest-$(date -u +%Y%m%d%H%M%S)"; export DR_ID
RESTORED_DB="app-pg-local-r$(date -u +%Y%m%d%H%M)"; PITR_DB="app-pg-local-p$(date -u +%Y%m%d%H%M)"
IP_OLD=172.30.0.21; IP_RESTORED=172.30.0.23
PASSN=0; FAILN=0; REPORT="$STATE/test-report.md"
printf '| # | Test | Result | Log |\n|---|---|---|---|\n' > "$REPORT"

_rec() { local n="$1" name="$2" ok="$3"
  if [[ "$ok" == 1 ]]; then PASSN=$((PASSN+1)); printf '✅ %-4s %s\n' "$n" "$name"; printf '| %s | %s | PASS | logs/%s.log |\n' "$n" "$name" "$n" >> "$REPORT"
  else FAILN=$((FAILN+1)); printf '❌ %-4s %s  (see %s)\n' "$n" "$name" "$LOGS/$n.log"; tail -15 "$LOGS/$n.log" | sed 's/^/      /'; printf '| %s | %s | **FAIL** | logs/%s.log |\n' "$n" "$name" "$n" >> "$REPORT"; fi; }
# t <id> <name> <cmd...>          : pass if cmd exits 0
t()  { local n="$1" name="$2"; shift 2; if ( "$@" ) > "$LOGS/$n.log" 2>&1; then _rec "$n" "$name" 1; else _rec "$n" "$name" 0; fi; }
# tf <id> <name> <grep> <cmd...>  : pass if cmd FAILS and output matches <grep> (negative tests)
tf() { local n="$1" name="$2" pat="$3"; shift 3; if ( "$@" ) > "$LOGS/$n.log" 2>&1; then _rec "$n" "$name" 0; else grep -Eq "$pat" "$LOGS/$n.log" && _rec "$n" "$name" 1 || _rec "$n" "$name" 0; fi; }
has() { grep -Eq "$1" "$2"; }
lib() { bash -c "source '$S/dr-lib.sh' && $*"; }
k()  { command kubectl --context dr-local -n app "$@"; }
sessions() { PGPASSWORD=masterpw psql "host=$1 dbname=app user=postgres sslmode=disable" -XAtqc \
  "select coalesce(string_agg(distinct application_name, ',' order by application_name),'') from pg_stat_activity where application_name like 'app-%'"; }
wait_sessions() { local ip="$1" want="$2" _; for _ in $(seq 1 45); do [[ "$(sessions "$ip")" == "$want" ]] && return 0; sleep 2; done
  echo "sessions on $ip: '$(sessions "$ip")' expected '$want'"; return 1; }
secret_host() { k get secret "$K8S_SECRET" -o jsonpath="{.data.$K8S_HOST_KEY}" | base64 -d; }

echo "=== A. Guardrails: wrong account / wrong cluster must be refused"
t  A01 "guard passes with the pinned profile + context"                lib dr_guard
tf A02 "wrong AWS profile (other account) is refused"   "is account"   env AWS_PROFILE=dr-decoy DR_GUARD_OK= bash -c "source '$S/dr-lib.sh' && dr_guard"
tf A03 "unknown kube context is refused"                "not found"    env EKS_CONTEXT=nope DR_GUARD_OK= bash -c "source '$S/dr-lib.sh' && dr_guard"
tf A04 "decoy context (other cluster) is refused"       "identifies as" env EKS_CONTEXT=decoy DR_GUARD_OK= bash -c "source '$S/dr-lib.sh' && dr_guard"
a05() { command kubectl --context dr-local -n kube-system patch configmap dr-cluster-identity --type merge -p '{"data":{"env":"uat"}}' >/dev/null
        local rc=0; DR_GUARD_OK='' bash -c "source '$S/dr-lib.sh' && dr_guard" && rc=1
        command kubectl --context dr-local -n kube-system patch configmap dr-cluster-identity --type merge -p '{"data":{"env":"local"}}' >/dev/null; return $rc; }
t  A05 "cluster whose identity says env=uat is refused"                a05
a06() { [[ "$(command kubectl config current-context)" == decoy ]] || return 1          # the CURRENT context is the decoy...
        command kubectl get ns >/dev/null 2>&1 && return 1                                # ...which is unreachable
        lib "dr_guard && kubectl -n app get deploy app-a -o name"; }                       # but the wrapper pins dr-local
t  A06 "kubectl wrapper ignores current-context (decoy) and uses EKS_CONTEXT" a06
tf A07 "local endpoint-map seam refused outside DR_ENV=local" "local-test seam" env DR_ENV=uat REQUIRE_CLUSTER_IDENTITY=false DR_GUARD_OK= bash -c "source '$S/dr-lib.sh' && dr_guard"
a08() { out="$(DR_ENV=prod bash -c "source '$S/dr-lib.sh' && dr_confirm 'test'" </dev/null 2>&1)"; rc=$?; echo "$out"; [[ $rc -ne 0 ]]; }
t  A08 "PROD confirmation blocks non-interactive changes (no DR_ASSUME_YES)" a08
t  A09 "aws wrapper pins profile: caller account = 000000000000" lib "aws sts get-caller-identity --query Account --output text | grep -qx 000000000000"

echo "=== B. Environment check, inventory, pre-flight"
t  B01 "dr-env-check.sh S3 → PASS"                                   "$S/dr-env-check.sh" S3
b02() { "$S/dr-eks-rollout.sh" inventory > "$LOGS/B02.inv" 2>&1; cat "$LOGS/B02.inv"
        has 'deployment/app-a .*reloader=YES' "$LOGS/B02.inv" && has 'statefulset/app-b .*reloader=YES' "$LOGS/B02.inv" \
        && has 'deployment/app-c .*reloader=NO' "$LOGS/B02.inv" && has 'cronjob/app-report' "$LOGS/B02.inv"; }
t  B02 "inventory: app-a/app-b Reloader YES, app-c NO, CronJob listed"  b02
t  B03 "preflight restore → PASS (inputs copied from source)"          "$S/dr-preflight.sh" restore
t  B04 "preflight replica → PASS"                                       "$S/dr-preflight.sh" replica

echo "=== C. S3 snapshot restore (DR_ID=$DR_ID)"
# shellcheck source=/dev/null
source "$S/dr-lib.sh"; dr_init S3 > "$LOGS/C00.log" 2>&1 || { echo "dr_init failed"; cat "$LOGS/C00.log"; exit 99; }
export OLD_DB="$PRIMARY_DB"
SNAP="$(aws rds describe-db-snapshots --db-instance-identifier "$PRIMARY_DB" --snapshot-type automated --query 'DBSnapshots[0].DBSnapshotIdentifier' --output text)"
t  C01 "list-snapshots"                                              "$S/dr-restore.sh" list-snapshots "$PRIMARY_DB"
c02() { "$S/dr-restore.sh" snapshot "$SNAP" "$RESTORED_DB" && has "sgs=\[sg-[0-9a-f]+ sg-[0-9a-f]+ sg-[0-9a-f]+\]" "$LOGS/C02.log"; }
t  C02 "restore snapshot → copies ALL 3 security groups from source"   c02
t  C03 "wait until available (progress + T5)"                          "$S/dr-restore.sh" wait "$RESTORED_DB"
t  C04 "harden: backup retention 7 + deletion protection"             bash -c "'$S/dr-restore.sh' harden '$RESTORED_DB' | grep -q '\"retention\": 7'"
t  C05 "restored instance has 3 SGs (exercise bug F3 fixed)"           bash -c "[[ \$(command aws --profile dr-local rds describe-db-instances --db-instance-identifier '$RESTORED_DB' --query 'length(DBInstances[0].VpcSecurityGroups)') == 3 ]]"
dr_set_target "$RESTORED_DB" > "$LOGS/C06.log" 2>&1
tf C06 "password trap: precheck FAILS (restored DB has the old password)" "LOGIN FAILED" "$S/dr-secret-cutover.sh" precheck
t  C07 "fix-password → precheck OK"                                    "$S/dr-secret-cutover.sh" fix-password
t  C08 "compare-counts: orders old=100 vs restored=80"                 bash -c "'$S/dr-verify.sh' compare-counts | grep -Eq 'public.orders +100 +80'"
t  C09 "DB verification SQL on restored"                               bash -c "psql \"\$TARGET_DSN\" -f '$ROOT/automation/sql/20-postfailover-verify.sql' | grep -vq FAIL"

echo "=== D. Cutover: secret → ESO → Reloader (app-c NOT annotated)"
APPC_POD_BEFORE="$(k get pods -l app=app-c -o jsonpath='{.items[0].metadata.name}')"
APPC_GEN_BEFORE="$(k get deploy app-c -o jsonpath='{.metadata.generation}')"
t  D01 "apply with RESTART_UNANNOTATED=false"                          env RESTART_UNANNOTATED=false "$S/dr-secret-cutover.sh" apply
t  D02 "K8s Secret POSTGRES_DB_HOST = restored endpoint"               bash -c "[[ \$(command kubectl --context dr-local -n app get secret $K8S_SECRET -o jsonpath='{.data.$K8S_HOST_KEY}' | base64 -d) == $IP_RESTORED ]]"
RPT="$DR_EVIDENCE_DIR/k8s/reload-report-$K8S_SECRET.txt"
t  D03 "Reloader restarted app-a and app-b"                            bash -c "grep -q 'deployment/app-a: RELOADED by Reloader' '$RPT' && grep -q 'statefulset/app-b: RELOADED by Reloader' '$RPT'"
t  D04 "app-c reported as UNANNOTATED → SKIPPED"                        grep -q 'deployment/app-c: UNANNOTATED → SKIPPED' "$RPT"
t  D05 "Reloader did NOT touch app-c (same pod, same generation)"       bash -c "[[ \$(command kubectl --context dr-local -n app get pods -l app=app-c -o jsonpath='{.items[0].metadata.name}') == $APPC_POD_BEFORE && \$(command kubectl --context dr-local -n app get deploy app-c -o jsonpath='{.metadata.generation}') == $APPC_GEN_BEFORE ]]"
t  D06 "sessions: restored = app-a,app-b · old = app-c"                 bash -c "$(declare -f sessions wait_sessions); wait_sessions $IP_RESTORED app-a,app-b && wait_sessions $IP_OLD app-c"
t  D07 "dr-verify connections: TARGET has app-a (query must succeed)"   bash -c "'$S/dr-verify.sh' connections | grep -A4 '== TARGET' | grep -q '^app-a'"
t  D08 "rollback with RESTART_UNANNOTATED=true → secret back to old"   env RESTART_UNANNOTATED=true "$S/dr-secret-cutover.sh" rollback
t  D09 "after rollback all 3 apps on old, none on restored"            bash -c "$(declare -f sessions wait_sessions); wait_sessions $IP_OLD app-a,app-b,app-c && wait_sessions $IP_RESTORED ''"
t  D10 "re-apply with RESTART_UNANNOTATED=true"                        env RESTART_UNANNOTATED=true "$S/dr-secret-cutover.sh" apply
t  D11 "app-c restarted manually (UNANNOTATED → manual rollout restart)" grep -q 'deployment/app-c: UNANNOTATED → manual rollout restart' "$RPT"
t  D12 "all 3 apps on restored, 0 on old"                               bash -c "$(declare -f sessions wait_sessions); wait_sessions $IP_RESTORED app-a,app-b,app-c && wait_sessions $IP_OLD ''"

echo "=== E. Fencing, CronJobs"
t  E01 "fence F1 readonly on old"                                      "$S/dr-fence-instance.sh" readonly "$OLD_DB"
t  E02 "old DB new sessions are read-only"                             bash -c "PGPASSWORD=masterpw psql 'host=$IP_OLD dbname=app user=postgres sslmode=disable' -XAtqc 'show default_transaction_read_only' | grep -qx on"
t  E03 "fence F2 quarantine SG on old"                                 "$S/dr-fence-instance.sh" quarantine "$OLD_DB"
t  E04 "old instance SGs = [quarantine]"                               bash -c "[[ \$(command aws --profile dr-local rds describe-db-instances --db-instance-identifier $OLD_DB --query 'DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId' --output text) == $QUARANTINE_SG ]]"
t  E05 "un-fence restores 3 SGs + read-write"                          bash -c "'$S/dr-fence-instance.sh' restore '$OLD_DB' && [[ \$(command aws --profile dr-local rds describe-db-instances --db-instance-identifier $OLD_DB --query 'length(DBInstances[0].VpcSecurityGroups)') == 3 ]] && PGPASSWORD=masterpw psql 'host=$IP_OLD dbname=app user=postgres sslmode=disable' -XAtqc 'show default_transaction_read_only' | grep -qx off"
t  E06 "suspend CronJobs"                                              bash -c "'$S/dr-eks-rollout.sh' suspend-cronjobs && [[ \$(command kubectl --context dr-local -n app get cronjob app-report -o jsonpath='{.spec.suspend}') == true ]]"
t  E07 "resume CronJobs"                                               bash -c "'$S/dr-eks-rollout.sh' resume-cronjobs && [[ \$(command kubectl --context dr-local -n app get cronjob app-report -o jsonpath='{.spec.suspend}') == false ]]"

echo "=== F. S2 promotion, S4 PITR"
f01() { dr_set_target "$REPLICA_DB" && aws rds promote-read-replica --db-instance-identifier "$REPLICA_DB" --backup-retention-period 7 >/dev/null \
        && TIMEOUT_SECONDS=120 "$S/dr-verify.sh" wait-promoted; }
t  F01 "S2 promote replica + wait-promoted (standalone + writable)"     f01
t  F02 "S4 PITR latest → hardened restore with 3 SGs"                   bash -c "'$S/dr-restore.sh' pitr '$PRIMARY_DB' '$PITR_DB' latest | grep -Eq 'sgs=\[sg-[0-9a-f]+ sg-[0-9a-f]+ sg-[0-9a-f]+\]'"

echo "=== G. Evidence, KPIs, SSM documents, tracker"
dr_mark T0 --at "$(date -u -d '-20 min' +%FT%T.000Z)" >/dev/null; dr_mark T9 >/dev/null; dr_mark T10 >/dev/null
t  G01 "phase timer + summary"                                          bash -c "source '$S/dr-lib.sh'; dr_phase start demo 1; dr_phase end demo 1; dr_summary | grep -q 'since T0'"
t  G02 "collect evidence → manifest uploaded to the evidence bucket"    bash -c "'$S/dr-collect-evidence.sh' && command aws --profile dr-local s3 ls s3://$EVIDENCE_BUCKET/local/ --recursive | grep -q '$DR_ID/manifest.json'"
t  G03 "KPI report: RPO from snapshot time, RTO ~20 min"                bash -c "grep -q 'restore point' '$DR_EVIDENCE_DIR/rto-rpo-report.md' && grep -Eq 'Business RTO \(T9-T0\) \| 2[01]' '$DR_EVIDENCE_DIR/rto-rpo-report.md'"
g04() { for d in DR-UpdateDbSecretEndpoint DR-RdsPromoteReplica DR-RdsRestoreFromSnapshot DR-RdsRestoreToPointInTime; do
          aws ssm create-document --name "$d-$RANDOM" --document-type Automation --document-format YAML --content "file://$ROOT/automation/ssm/$d.yaml" --query DocumentDescription.Status --output text || return 1; done; }
t  G04 "SSM Automation documents accepted (create-document)"            g04
t  G05 "tracker CSV generated for every runbook"                        bash -c "for f in '$ROOT'/runbooks/*/RB-*.md; do python3 '$S/runbook-to-tracker.py' \"\$f\" -o /dev/null || exit 1; done"

echo; echo "PASS=$PASSN FAIL=$FAILN  (report: $REPORT, evidence: $DR_EVIDENCE_DIR)"
printf '\n**PASS=%s FAIL=%s** · DR_ID=%s · %s\n' "$PASSN" "$FAILN" "$DR_ID" "$(date -u +%FT%TZ)" >> "$REPORT"
exit "$FAILN"
