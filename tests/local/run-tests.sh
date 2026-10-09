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
a06() { command kubectl config use-context decoy >/dev/null; local rc=0             # make the decoy CURRENT for this test
        command kubectl --request-timeout=5s get ns >/dev/null 2>&1 && rc=1               # ...it is unreachable
        DR_STRICT_PIN=0 DR_ALLOW_CURRENT_CONTEXT=1 DR_GUARD_OK='' lib "dr_guard && kubectl -n app get deploy app-a -o name" || rc=1  # fill-in mode pins dr-local
        command kubectl config unset current-context >/dev/null; return $rc; }
t  A06 "fill-in mode (DR_STRICT_PIN=0) ignores current-context (decoy), uses EKS_CONTEXT" a06
tf A07 "local endpoint-map seam refused outside DR_ENV=local" "local-test seam" env DR_ENV=uat REQUIRE_CLUSTER_IDENTITY=false DR_GUARD_OK= bash -c "source '$S/dr-lib.sh' && dr_guard"
a08() { out="$(DR_ENV=prod bash -c "source '$S/dr-lib.sh' && dr_confirm 'test'" </dev/null 2>&1)"; rc=$?; echo "$out"; [[ $rc -ne 0 ]]; }
t  A08 "PROD confirmation blocks non-interactive changes (no DR_ASSUME_YES)" a08
t  A09 "pinned aws call: caller account = 000000000000"           lib 'aws --profile "$AWS_PROFILE" --region "$AWS_REGION" sts get-caller-identity --query Account --output text | grep -qx 000000000000'
# strict pinning (default): a missing or foreign profile/context is REFUSED (exit 97), never filled in
r97() { lib "$1"; local rc=$?; echo "rc=$rc"; [[ $rc == 97 ]]; }
t  A10 "strict: aws without --profile/--region → REFUSED (97)"       r97 'aws sts get-caller-identity'
t  A11 "strict: aws --profile dr-decoy → REFUSED (97), even with DR_STRICT_PIN=0" r97 'DR_STRICT_PIN=0; aws --profile dr-decoy --region eu-west-1 sts get-caller-identity'
t  A12 "strict: kubectl without --context → REFUSED (97)"            r97 'kubectl -n app get pods'
t  A13 "strict: kubectl --context decoy → REFUSED (97)"              r97 'kubectl --context decoy -n app get pods'
a14() { local cfg="$STATE/aws-config.default"; { cat "$AWS_CONFIG_FILE"; printf '[default]\nregion = eu-west-1\n'; } > "$cfg"
        env AWS_CONFIG_FILE="$cfg" DR_GUARD_OK= bash -c "source '$S/dr-lib.sh' && dr_guard"; local rc=$?; rm -f "$cfg"; return $rc; }
tf A14 "a [default] AWS profile makes the guard fail"   "\[default\] AWS profile" a14
a15() { command kubectl config use-context decoy >/dev/null; DR_GUARD_OK='' bash -c "source '$S/dr-lib.sh' && dr_guard"; local rc=$?
        command kubectl config unset current-context >/dev/null; return $rc; }
tf A15 "a kube current-context makes the guard fail"     "current-context" a15
a16() { local kc="$STATE/kubeconfig.foreign"; cp "$KUBECONFIG" "$kc"
        KUBECONFIG="$kc" command kubectl config set-context dr-prod --cluster=decoy --user=dr-local >/dev/null
        KUBECONFIG="$kc" DR_GUARD_OK='' bash -c "source '$S/dr-lib.sh' && dr_guard"; local rc=$?; rm -f "$kc"; return $rc; }
tf A16 "kubeconfig holding another env's context (dr-prod) makes the guard fail" "other environments" a16
tf A17 "exported static AWS keys are refused (strict)"   "REFUSED: AWS_ACCESS_KEY_ID" env AWS_ACCESS_KEY_ID=AKIAEXAMPLE AWS_SECRET_ACCESS_KEY=x bash -c "source '$S/dr-lib.sh'"
t  A18 "pinning lint: every aws/kubectl call in the scripts is pinned" "$ROOT/tests/lint/pinning-lint.sh"
# authentication kinds: static key in a named profile (dr-local) and SSO are both accepted; PROD can forbid keys; expiry is explained
t  A19 "auth types detected: dr-local = key, dr-sso-expired = sso"     bash -c "source '$S/dr-lib.sh' && [[ \$(_dr_auth_type dr-local) == key && \$(_dr_auth_type dr-sso-expired) == sso && \$(_dr_auth_type nope) == none ]]"
t  A20 "guard OK line shows auth=key (static key in a named profile)"   bash -c "DR_GUARD_OK= bash -c \"source '$S/dr-lib.sh' && dr_guard\" 2>&1 | grep -q 'auth=key'"
tf A21 "DR_AUTH_ALLOWED=sso,role refuses a static-key profile"           "uses 'key' credentials; allowed here: sso,role" env DR_AUTH_ALLOWED=sso,role DR_GUARD_OK= bash -c "source '$S/dr-lib.sh' && dr_guard"
tf A22 "expired SSO (no tty): tells you the exact login command"         "aws sso login --profile dr-sso-expired" env AWS_PROFILE=dr-sso-expired DR_GUARD_OK= bash -c "source '$S/dr-lib.sh' && dr_guard </dev/null"
tf A23 "unknown profile name is refused (no silent fallback)"            "not found" env AWS_PROFILE=no-such-profile DR_GUARD_OK= bash -c "source '$S/dr-lib.sh' && dr_guard"
tf A24 "static key rejected → not an SSO profile, says what to check"    "not an SSO profile" env DR_GUARD_OK= bash -c "source '$S/dr-lib.sh'; AWS_PROFILE=dr-decoy; ACCOUNT_ID=000000000000; dr_reauth </dev/null"

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
SNAP="$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-snapshots --db-instance-identifier "$PRIMARY_DB" --snapshot-type automated --query 'DBSnapshots[0].DBSnapshotIdentifier' --output text)"
export WAIT_POLL_S=3 HARDEN_SETTLE_S=2
FX="$HERE/fixtures/rds-primary-uat-like.json"; JQL="$(cat "$S/rds-requests.jq")"
c00() { "$S/dr-restore.sh" capture "$PRIMARY_DB" && jq -e --slurpfile fx "$FX" '([.tags[] | select(.Key | startswith("aws:") | not)] | length) == 4
          and ([.tags[] | select(.Key | startswith("aws:"))] | length) == 3 and (.pgSettings | length) > 100
          and (.instance.VpcSecurityGroups | length) == ($fx[0].VpcSecurityGroups | length)
          and (.instance.DBSubnetGroup.Subnets | length) == ($fx[0].DBSubnetGroup.Subnets | length)' "$BASELINE_DIR/baseline-$PRIMARY_DB.json"; }
t  C00 "capture baseline of the UAT-shaped source (3 SGs, 3 subnets, 4 user + 3 aws:* tags, pg_settings)" c00
t  C01 "list-snapshots"                                              "$S/dr-restore.sh" list-snapshots "$PRIMARY_DB"
REQ="$DR_EVIDENCE_DIR/aws/restore-request-$RESTORED_DB.json"
c01b() { "$S/dr-restore.sh" plan snapshot "$SNAP" "$RESTORED_DB" && jq -e --slurpfile fx "$FX" '$fx[0] as $f | (.VpcSecurityGroupIds | length) == 3 and (has("BackupRetentionPeriod") | not) and (has("PreferredBackupWindow") | not)
           and .DBSubnetGroupName == $f.DBSubnetGroup.DBSubnetGroupName and .DBParameterGroupName == $f.DBParameterGroups[0].DBParameterGroupName
           and .EnableCloudwatchLogsExports == $f.EnabledCloudwatchLogsExports
           and .CopyTagsToSnapshot == $f.CopyTagsToSnapshot and .DeletionProtection and .CACertificateIdentifier == $f.CACertificateIdentifier
           and ([.Tags[] | select(.Key == "cost-center")][0].Value == "CC 1234 / retail") and ([.Tags[].Key] | index("dr-restore") != null)
           and ([.Tags[].Key | select(startswith("aws:"))] | length) == 0' "$REQ" \
         && ! command aws --profile dr-local rds describe-db-instances --db-instance-identifier "$RESTORED_DB" >/dev/null 2>&1; }
t  C01b "plan: request from baseline (3 SGs, subnet group, PG, retention 7, window, logs, CA, user tags, NO aws:* tags) — no change" c01b
c02() { "$S/dr-restore.sh" snapshot "$SNAP" "$RESTORED_DB" && has "sgs=\[sg-[0-9a-f]+ sg-[0-9a-f]+ sg-[0-9a-f]+\]" "$LOGS/C02.log"; }
t  C02 "restore snapshot with the baseline request (--cli-input-json)"  c02
t  C03 "wait until available (progress + T5)"                          "$S/dr-restore.sh" wait "$RESTORED_DB"
# right after the restore the request already carried SGs/subnets/PG/retention/tags (the maintenance window may still differ:
# real AWS assigns a random one, moto copies the snapshot's → harden fixes it; not asserted here)
c03b() { "$S/dr-restore.sh" validate "$RESTORED_DB"; ! grep -E '^DIFF +(VpcSecurityGroups|DBSubnetGroup|DBParameterGroups|DeletionProtection|EnabledCloudwatchLogsExports|tag )' "$LOGS/C03b.log"; }
t  C03b "validate right after restore: SGs, subnets, PG, retention 7, logs, tags already match" c03b
c03c() { local arn; arn="$(command aws --profile dr-local rds describe-db-instances --db-instance-identifier "$RESTORED_DB" --query 'DBInstances[0].DBInstanceArn' --output text)"
         command aws --profile dr-local rds modify-db-instance --db-instance-identifier "$RESTORED_DB" --backup-retention-period 1 --apply-immediately >/dev/null
         command aws --profile dr-local rds remove-tags-from-resource --resource-name "$arn" --tag-keys cost-center
         ! "$S/dr-restore.sh" validate "$RESTORED_DB" && has 'DIFF +BackupRetentionPeriod: expected 7 +actual 1' "$LOGS/C03c.log" && has 'DIFF +tag cost-center' "$LOGS/C03c.log"; }
t  C03c "CLI default retention 1 day + lost tag → validate detects both"  c03c
t  C04 "harden converges to baseline (retention 7, window, tag) → VALIDATED" bash -c "'$S/dr-restore.sh' harden '$RESTORED_DB' | grep -q '→ VALIDATED\$'"
c05() { local j; j="$(command aws --profile dr-local rds describe-db-instances --db-instance-identifier "$RESTORED_DB" --query 'DBInstances[0]')"
        jq -e '(.VpcSecurityGroups | length) == 3 and .BackupRetentionPeriod == 7 and .DeletionProtection' <<<"$j" \
        && command aws --profile dr-local rds list-tags-for-resource --resource-name "$(jq -r .DBInstanceArn <<<"$j")" \
           | jq -e '[.TagList[].Key] | contains(["app","owner","cost-center","backup-plan","dr-restore","dr-restored-from"])'; }
t  C05 "restored instance: 3 SGs, retention 7, deletion protection, all source tags" c05
dr_set_target "$RESTORED_DB" > "$LOGS/C06.log" 2>&1
tf C06 "password trap: precheck FAILS (restored DB has the old password)" "LOGIN FAILED" "$S/dr-secret-cutover.sh" precheck
t  C07 "fix-password → precheck OK"                                    "$S/dr-secret-cutover.sh" fix-password
t  C07b "validate-pg: pg_settings restored == source"                    "$S/dr-restore.sh" validate-pg
mpsql() { PGPASSWORD=masterpw psql "host=$1 dbname=app user=postgres sslmode=disable" -XAtqc "$2"; }
c07c() { mpsql "$IP_RESTORED" "alter database app set work_mem = '7MB'" && ! "$S/dr-restore.sh" validate-pg; local rc=$?
         mpsql "$IP_RESTORED" "alter database app reset work_mem"; (( rc == 0 )) && has 'DIFF +work_mem' "$LOGS/C07c.log" && "$S/dr-restore.sh" validate-pg; }
t  C07c "validate-pg detects a changed parameter (work_mem), passes after reset" c07c
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
SCT=("$S/k8s-secret-consumers.sh" --context dr-local -n app -s "$K8S_SECRET")
tf D07a "secret-consumers tool refuses without --context"              "context.*mandatory" env -u EKS_CONTEXT "$S/k8s-secret-consumers.sh" -n app -s "$K8S_SECRET" check
tf D07b "secret-consumers tool refuses a cluster that is not env=prod"   "REFUSED" "${SCT[@]}" --expect-env prod check
d07c() { ! "${SCT[@]}" --expect-env local check && has '^STALE +deployment/app-c' "$LOGS/D07c.log" \
         && has '^UP-TO-DATE +deployment/app-a' "$LOGS/D07c.log" && has '^UP-TO-DATE +statefulset/app-b' "$LOGS/D07c.log" && has '^stale=1' "$LOGS/D07c.log"; }
t  D07c "check: app-c STALE, app-a/app-b UP-TO-DATE (exit 1)"           d07c
d07d() { local ga gb gc; ga=$(k get deploy app-a -o jsonpath='{.metadata.generation}'); gb=$(k get sts app-b -o jsonpath='{.metadata.generation}')
         gc=$(k get deploy app-c -o jsonpath='{.metadata.generation}')
         "$S/dr-eks-rollout.sh" restart-stale && has 'restarting deployment/app-c' "$LOGS/D07d.log" && has '^restarted=1' "$LOGS/D07d.log" \
         && [[ $(k get deploy app-a -o jsonpath='{.metadata.generation}') == "$ga" && $(k get sts app-b -o jsonpath='{.metadata.generation}') == "$gb" \
               && $(k get deploy app-c -o jsonpath='{.metadata.generation}') -gt "$gc" ]]; }
t  D07d "restart-stale restarts ONLY app-c (app-a/app-b generation unchanged)" d07d
t  D07e "check after restart: all UP-TO-DATE (exit 0), app-c on restored" bash -c "$(declare -f sessions wait_sessions); '${SCT[0]}' ${SCT[*]:1} check && wait_sessions $IP_RESTORED app-a,app-b,app-c"
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
f01() { dr_set_target "$REPLICA_DB" && aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds promote-read-replica --db-instance-identifier "$REPLICA_DB" --backup-retention-period 7 >/dev/null \
        && TIMEOUT_SECONDS=120 "$S/dr-verify.sh" wait-promoted; }
t  F01 "S2 promote replica + wait-promoted (standalone + writable)"     f01
t  F02 "S4 PITR latest → restore request from baseline with 3 SGs"      bash -c "'$S/dr-restore.sh' pitr '$PRIMARY_DB' '$PITR_DB' latest && jq -e '(.VpcSecurityGroupIds | length) == 3 and .UseLatestRestorableTime and (has("BackupRetentionPeriod") | not)' '$DR_EVIDENCE_DIR/aws/restore-request-$PITR_DB.json'"
t  F03 "S4 PITR: wait + harden → VALIDATED against the baseline"        bash -c "'$S/dr-restore.sh' wait '$PITR_DB' && '$S/dr-restore.sh' harden '$PITR_DB' | grep -q '→ VALIDATED\$'"

echo "=== G. Evidence, KPIs, SSM documents, tracker"
dr_mark T0 --at "$(date -u -d '-20 min' +%FT%T.000Z)" >/dev/null; dr_mark T9 >/dev/null; dr_mark T10 >/dev/null
g00() { printf 'aws --profile dr-local --region eu-west-1 sts get-caller-identity --query Account --output text\nexport PGPASSWORD=supersecret\naws sts get-caller-identity\nexit\n' \
          | "$S/dr-session.sh" "$STATE/local.env" S3; local L; L="$(ls -t "$DR_EVIDENCE_DIR"/terminal/session-*.log | head -1)"
        grep -q 000000000000 "$L" && grep -q 'REFUSED aws' "$L" && grep -q 'PGPASSWORD=\*\*\*' "$L" && ! grep -q 'ersecret' "$L" \
        && grep -q 'get-caller-identity' "$DR_EVIDENCE_DIR"/terminal/history-*.txt && [[ ! -e "${L%.log}.raw" ]] \
        && command aws --profile dr-local s3 ls "s3://$EVIDENCE_BUCKET/local/" --recursive | grep "$DR_ID/terminal/session-" >/dev/null; }
t  G00 "recorded session: transcript + history, password redacted, REFUSED shown, synced to S3" g00
g00b() { lib 'aws --profile "$AWS_PROFILE" --region "$AWS_REGION" secretsmanager create-secret --name local/dr-test/redact-$RANDOM --secret-string "{\"password\":\"pw-must-not-appear\"}" >/dev/null' \
         && ! grep -q 'pw-must-not-appear' "$DR_EVIDENCE_DIR/commands.jsonl" && grep -q '"--secret-string","\*\*\*"' "$DR_EVIDENCE_DIR/commands.jsonl" \
         && jq -e 'select(.status=="REFUSED" and .rc==97)' "$DR_EVIDENCE_DIR/commands.jsonl" >/dev/null; }
t  G00b "audit log commands.jsonl: every call, secret-string redacted, refusals recorded" g00b
t  G01 "phase timer + summary"                                          bash -c "source '$S/dr-lib.sh'; dr_phase start demo 1; dr_phase end demo 1; dr_summary | grep -q 'since T0'"
t  G01b "dr_phase end syncs the evidence folder to S3 (timeline already off the machine)" bash -c "command aws --profile dr-local s3 ls s3://$EVIDENCE_BUCKET/local/ --recursive | grep -q '$DR_ID/timeline.jsonl'"
t  G02 "collect evidence → manifest uploaded to the evidence bucket"    bash -c "'$S/dr-collect-evidence.sh' && command aws --profile dr-local s3 ls s3://$EVIDENCE_BUCKET/local/ --recursive | grep -q '$DR_ID/manifest.json'"
t  G03 "KPI report: RPO from snapshot time, RTO ~20 min"                bash -c "grep -q 'restore point' '$DR_EVIDENCE_DIR/rto-rpo-report.md' && grep -Eq 'Business RTO \(T9-T0\) \| 2[01]' '$DR_EVIDENCE_DIR/rto-rpo-report.md'"
g04() { for d in DR-UpdateDbSecretEndpoint DR-RdsPromoteReplica DR-RdsRestoreFromSnapshot DR-RdsRestoreToPointInTime; do
          aws --profile "$AWS_PROFILE" --region "$AWS_REGION" ssm create-document --name "$d-$RANDOM" --document-type Automation --document-format YAML --content "file://$ROOT/automation/ssm/$d.yaml" --query DocumentDescription.Status --output text || return 1; done; }
t  G04 "SSM Automation documents accepted (create-document)"            g04
t  G05 "tracker CSV generated for every runbook"                        bash -c "for f in '$ROOT'/runbooks/*/RB-*.md; do python3 '$S/runbook-to-tracker.py' \"\$f\" -o /dev/null || exit 1; done"

echo "=== I. UAT-shaped requests (offline, from the sanitised UAT describe) + create-like round trip"
ireq() { jq -S --argjson ov '{}' "$JQL"' (.TagList | userTags) as $t | expected($ov; "uat"; 7; false) | '"$1" "$FX"; }
i01() { ireq 'restore_req({DBInstanceIdentifier:"x", DBSnapshotIdentifier:"s"}; $t)' | tee /dev/stderr | jq -e '
          (.VpcSecurityGroupIds | length) == 3 and .DBSubnetGroupName == "app-uat-rdssubnetgroup-example" and .DBParameterGroupName == "app-postgres-17"
          and (has("OptionGroupName") | not) and (has("Iops") | not) and (has("StorageThroughput") | not) and .Port == 5432
          and .BackupRetentionPeriod == 7 and .PreferredBackupWindow == "17:58-18:28" and .CACertificateIdentifier == "rds-ca-rsa2048-g1"
          and .EnableCloudwatchLogsExports == ["postgresql"] and .DeletionProtection and (.CopyTagsToSnapshot == false)
          and .EngineLifecycleSupport == "open-source-rds-extended-support" and .BackupTarget == "region" and .LicenseModel == "postgresql-license"
          and .NetworkType == "IPV4" and ((.Tags // []) | length) == 0'; }
t  I01 "restore request (UAT): 3 SGs, subnet group, PG, no default option group, no gp3 IOPS <400GB, port 5432 (not DbInstancePort 0), lifecycle/backup target/license, no aws:* tags" i01
i02() { local tg; tg="$(jq -c '.PreferredMaintenanceWindow="mon:03:10-mon:03:40" | .MonitoringInterval=0 | del(.MonitoringRoleArn) | .PerformanceInsightsEnabled=false
                             | del(.PerformanceInsightsKMSKeyId,.PerformanceInsightsRetentionPeriod,.DatabaseInsightsMode) | .BackupRetentionPeriod=1' "$FX")"
        jq -S --argjson ov '{}' --argjson tg "$tg" "$JQL"' expected($ov; "uat"; 7; false) | harden_req($tg; "x")' "$FX" | tee /dev/stderr | jq -e '
          .PreferredMaintenanceWindow == "thu:19:30-thu:20:00" and .MonitoringInterval == 60 and (.MonitoringRoleArn | endswith(":role/rds-monitoring-role"))
          and .EnablePerformanceInsights and .PerformanceInsightsRetentionPeriod == 7 and (.PerformanceInsightsKMSKeyId | startswith("arn:aws:kms:"))
          and .DatabaseInsightsMode == "standard" and .BackupRetentionPeriod == 7 and .ApplyImmediately'; }
t  I02 "harden request (UAT) after a restore: maintenance window, Enhanced Monitoring 60s + role, PI + KMS + 7d, Database Insights, retention 1→7" i02
i03() { ireq 'create_req("x"; $t; {})' | tee /dev/stderr | jq -e '.Engine == "postgres" and .EngineVersion == "17.9" and .MasterUsername == "postgres"
          and .ManageMasterUserPassword and (has("MasterUserPassword") | not) and .AllocatedStorage == 20 and .StorageType == "gp3" and (has("Iops") | not)
          and .MonitoringInterval == 60 and .EnablePerformanceInsights and .PreferredMaintenanceWindow == "thu:19:30-thu:20:00" and (.StorageEncrypted == false)'; }
t  I03 "create-like request (UAT): engine 17.9, RDS-managed master password, gp3 20GB, monitoring + PI + window at create" i03
i04() { jq -n --slurpfile f "$FX" "$JQL"' ($f[0] | norm) as $a
          | ($f[0] | .DBInstanceIdentifier="other" | .DbiResourceId="db-X" | .Endpoint.Address="other.host" | .UpgradeRolloutOrder="first"
             | .InstanceCreateTime="2030-01-01" | .AutomaticRestartTime=null | .CertificateDetails.ValidTill="x" | norm) as $b
          | [$a | keys[] | select(($a[.] | tojson) != ($b[.] | tojson))] | if . == [] then true else error("diff: \(.)") end'; }
t  I04 "validate ignores identity/runtime fields + UpgradeRolloutOrder (not settable), compares everything else" i04
CL_DB="${PRIMARY_DB}-c$(date -u +%H%M%S)"
i05() { CREATE_OVERRIDES='{"MasterUserPassword":"masterpw"}' "$S/dr-restore.sh" create-like "$PRIMARY_DB" "$CL_DB" \
        && "$S/dr-restore.sh" wait "$CL_DB" && "$S/dr-restore.sh" harden "$CL_DB" | tee /dev/stderr | grep -q '→ VALIDATED$'; }
t  I05 "create-like: empty test instance with the primary's configuration → harden → VALIDATED" i05
command aws --profile dr-local rds modify-db-instance --db-instance-identifier "$CL_DB" --no-deletion-protection --apply-immediately >/dev/null 2>&1
command aws --profile dr-local rds delete-db-instance --db-instance-identifier "$CL_DB" --skip-final-snapshot >/dev/null 2>&1

echo "=== H. SECRET_MODE=k8s: plain Secret with TWO host keys, ledger IDs, failback by ID, Reloader alert"
IP_REPLICA=172.30.0.22
EPT=("$S/k8s-secret-endpoint.sh" --context dr-local -n app -s app-db-direct -k "POSTGRES_DB_HOST1,POSTGRES_DB_HOST2" --expect-env local)
dhosts() { k get secret app-db-direct -o json | jq -r '[.data.POSTGRES_DB_HOST1, .data.POSTGRES_DB_HOST2] | map(@base64d) | join(",")'; }
dsessions() { PGPASSWORD=masterpw psql "host=$1 dbname=app user=postgres sslmode=disable" -XAtqc \
  "select coalesce(string_agg(distinct application_name, ',' order by application_name),'') from pg_stat_activity where application_name like 'direct-%'"; }
wait_dsessions() { local _; for _ in $(seq 1 45); do [[ "$(dsessions "$1")" == "$2" ]] && return 0; sleep 2; done; echo "direct sessions on $1: '$(dsessions "$1")' expected '$2'"; return 1; }
KMODE=(env SECRET_MODE=k8s K8S_SECRET=app-db-direct "K8S_HOST_KEY=POSTGRES_DB_HOST1,POSTGRES_DB_HOST2" K8S_PORT_KEY=POSTGRES_DB_PORT OLD_DB="$PRIMARY_DB")
C1="DR-$(date -u +%Y%m%d-%H%M)-local-S3"; C2="DR-$(date -u +%Y%m%d-%H%M)-local-S2"; FB="DR-$(date -u +%Y%m%d-%H%M)-local-FB-S3S4"
t  H01 "show: both host keys = old primary, not managed by ESO"         bash -c "'${EPT[0]}' ${EPT[*]:1} show | tee /dev/stderr | grep -q 'not managed by ESO' && [[ \$(command kubectl --context dr-local -n app get secret app-db-direct -o json | jq -r '[.data.POSTGRES_DB_HOST1,.data.POSTGRES_DB_HOST2]|map(@base64d)|join(\",\")') == $IP_OLD,$IP_OLD ]]"
tf H02 "refuses to patch an ESO-owned Secret (ESO would revert it)"     "owned by ExternalSecret" "$S/k8s-secret-endpoint.sh" --context dr-local -n app -s "$K8S_SECRET" -k "$K8S_HOST_KEY" set --host 1.2.3.4 --db-id x --id DR-test-eso
tf H03 "refuses an ID with spaces / bad characters"                      "must match" "${EPT[@]}" set --host 1.2.3.4 --db-id x --id "bad id"
t  H04 "preflight (SECRET_MODE=k8s): host keys present, not ESO-owned"   bash -c "env SECRET_MODE=k8s K8S_SECRET=app-db-direct K8S_HOST_KEY=POSTGRES_DB_HOST1,POSTGRES_DB_HOST2 '$S/dr-preflight.sh' restore | grep -q 'not managed by ESO'"
dr_set_target "$RESTORED_DB" >/dev/null 2>&1
h05() { "${KMODE[@]}" CUTOVER_ID="$C1" TARGET_DB="$RESTORED_DB" RESTART_UNANNOTATED=false "$S/dr-secret-cutover.sh" apply \
        && [[ "$(dhosts)" == "$IP_RESTORED,$IP_RESTORED" ]] \
        && [[ "$(k get secret app-db-direct -o jsonpath='{.metadata.annotations.dr\.example\.com/cutover-id}')" == "$C1" ]] \
        && [[ "$(k get secret app-db-direct -o jsonpath='{.metadata.annotations.dr\.example\.com/endpoint-db-id}')" == "$RESTORED_DB" ]]; }
t  H05 "cutover #1 (id $C1): BOTH keys → restored, annotations cutover-id + db-id" h05
h06() { local e; e="$(k get configmap dr-endpoint-ledger-app-db-direct -o json | jq -c '[.data[] | fromjson] | sort_by(.seq) | last')"; echo "$e"
        jq -e --arg id "$C1" --arg o "$IP_OLD" --arg n "$IP_RESTORED" --arg fdb "$PRIMARY_DB" --arg tdb "$RESTORED_DB" \
          '.id == $id and .type == "cutover" and .fromDb == $fdb and .toDb == $tdb and .keys.POSTGRES_DB_HOST1.from == $o
           and .keys.POSTGRES_DB_HOST2.to == $n and .port.to == "5432"' <<<"$e"; }
t  H06 "ledger entry #1: id, old→new endpoint per key, old/new DB identifier" h06
t  H07 "Reloader restarted app-d; app-e (no annotation) SKIPPED"          bash -c "grep -q 'deployment/app-d: RELOADED' '$DR_EVIDENCE_DIR/k8s/reload-report-app-db-direct.txt' && grep -q 'deployment/app-e: UNANNOTATED → SKIPPED' '$DR_EVIDENCE_DIR/k8s/reload-report-app-db-direct.txt'"
h08() { local out rc; out="$("$S/k8s-secret-consumers.sh" --context dr-local -n app -s app-db-direct check)"; rc=$?; echo "$out"
        (( rc != 0 )) && grep -qE '^STALE +deployment/app-e' <<<"$out" \
        && "$S/k8s-secret-consumers.sh" --context dr-local -n app -s app-db-direct restart | tee /dev/stderr | grep -q '^restarted=1' \
        && wait_dsessions "$IP_RESTORED" direct-d,direct-e; }
t  H08 "stale check finds app-e (HOST2), restart-stale → both apps on restored" h08
h09() { local l; for _ in $(seq 1 20); do l="$(k -n reloader logs deploy/reloader-alert-sink --tail=-1 2>/dev/null)"; grep -q 'reloaded app-d of type' <<<"$l" && break; sleep 3; done
        echo "$l" | tail -15; grep -q 'changes in app-db-direct of type SECRET' <<<"$l" && grep -q 'reloaded app-d of type' <<<"$l" && grep -q 'cluster=dr-local' <<<"$l"; }
t  H09 "Reloader ALERT webhook received the reload (secret, app-d, cluster info)" h09
t  H10 "cutover #2 (id $C2): → promoted replica"                         bash -c "$(declare -f dhosts k); ${KMODE[*]} CUTOVER_ID=$C2 TARGET_DB=$REPLICA_DB '$S/dr-secret-cutover.sh' apply && [[ \$(dhosts) == $IP_REPLICA,$IP_REPLICA ]]"
h11() { "${KMODE[@]}" CUTOVER_ID="$FB" "$S/dr-secret-cutover.sh" failback "$C1" && [[ "$(dhosts)" == "$IP_OLD,$IP_OLD" ]] \
        && wait_dsessions "$IP_OLD" direct-d,direct-e; }
t  H11 "failback to the endpoint before #1 (id $FB → ref $C1): both keys + both apps on old primary" h11
h12() { "${KMODE[@]}" "$S/dr-secret-cutover.sh" history | tee /dev/stderr > "$LOGS/H12.hist"
        [[ $(wc -l < "$LOGS/H12.hist") == 3 ]] && grep -q "CUTOVER  $C1" "$LOGS/H12.hist" && grep -q "CUTOVER  $C2" "$LOGS/H12.hist" \
        && grep -q "FAILBACK  $FB  (ref $C1)" "$LOGS/H12.hist" \
        && grep -q "CUTOVER  $C2  $RESTORED_DB → $REPLICA_DB" "$LOGS/H12.hist"; }   # "from" = what the Secret pointed at, not OLD_DB
t  H12 "history: #1 cutover, #2 cutover, #3 failback (ref #1) — who/when/from→to" h12
t  H13 "rollback undoes the latest change (failback) → replica again"   bash -c "$(declare -f dhosts k); ${KMODE[*]} CUTOVER_ID=$FB-undo '$S/dr-secret-cutover.sh' rollback && [[ \$(dhosts) == $IP_REPLICA,$IP_REPLICA ]]"
h14() { k patch secret app-db-direct --type merge -p '{"data":{"POSTGRES_DB_HOST1":"'"$(printf 9.9.9.9 | base64)"'"}}' >/dev/null
        "${EPT[@]}" rollback --id DR-test-refuse; local rc=$?
        k patch secret app-db-direct --type merge -p '{"data":{"POSTGRES_DB_HOST1":"'"$(printf "$IP_REPLICA" | base64)"'"}}' >/dev/null; return $rc; }
tf H14 "rollback refuses when the Secret was changed outside the ledger" "changed outside the ledger" h14

# read-only secret in k8s mode: its own Secret/host key; the primary keys must not move; no T6/T7 for it
RO_ENV=(env SECRET_MODE=k8s K8S_SECRET=app-db-primary-stub K8S_HOST_KEY=X K8S_SECRET_RO=app-db-direct K8S_HOST_KEY_RO=POSTGRES_DB_HOST1 K8S_PORT_KEY= CUTOVER_SECRET=ro)
h15() { k delete configmap dr-endpoint-ledger-app-db-direct --ignore-not-found >/dev/null
        k patch secret app-db-direct --type merge -p '{"stringData":{"POSTGRES_DB_HOST1":"'"$IP_OLD"'","POSTGRES_DB_HOST2":"'"$IP_OLD"'"}}' >/dev/null
        local t6; t6="$(grep -c '"marker":"T[67]"' "$DR_TIMELINE")"
        "${RO_ENV[@]}" TARGET_DB="$REPLICA_DB" RESTART_UNANNOTATED=false "$S/dr-secret-cutover.sh" apply \
        && [[ "$(dhosts)" == "$IP_REPLICA,$IP_OLD" ]] && [[ "$(grep -c '"marker":"T[67]"' "$DR_TIMELINE")" == "$t6" ]]; }
t  H15 "CUTOVER_SECRET=ro: only the RO host key moves (HOST1), HOST2 untouched, no T6/T7"  h15
tf H16 "revert with a different key list than the change used is refused"  "was written for keys" "${EPT[@]}" rollback --id DR-test-keys
t  H17 "RO rollback (same key list) restores the RO key only"   bash -c "$(declare -f dhosts k); ${RO_ENV[*]} '$S/dr-secret-cutover.sh' rollback && [[ \$(dhosts) == $IP_OLD,$IP_OLD ]]"

echo "=== J. dr-run.sh: step-by-step runner (SECRET_MODE=k8s, app-db-direct), gates auto, failure blocking, stop + resume"
RUN="$S/dr-run.sh"; JTS="$(date -u +%H%M%S)"; JS3="DR-localtest-run-S3-$JTS"; JF="DR-localtest-run-F-$JTS"; JS4="DR-localtest-run-S4-$JTS"
JENV=(env -u DR_EVIDENCE_DIR -u DR_TIMELINE SECRET_MODE=k8s K8S_SECRET=app-db-direct "K8S_HOST_KEY=POSTGRES_DB_HOST1,POSTGRES_DB_HOST2" K8S_PORT_KEY=POSTGRES_DB_PORT
      OLD_DB="$PRIMARY_DB" DR_RUN_GATES=auto FENCE=skip)
jdir() { echo "$ROOT/evidence/$1"; }
jst()  { awk -F'\t' -v i="$2" '$1==i{s=$2} END{print s}' "$(jdir "$1")/run-state.tsv"; }
j01() { "$RUN" S3 --list | tee /dev/stderr | grep -c '^P[0-9]' | grep -qx 20 && "$RUN" S4 --list | grep -c '^P[0-9]' | grep -qx 22; }
t  J01 "--list: S3 = 20 steps, S4 = 22 steps (IDs as in the runbooks), no AWS access needed" j01
j02() { local d; d="$(jdir DR-localtest-dry-$JTS)"; DR_ID="DR-localtest-dry-$JTS" "$RUN" S3 --dry-run | tee /dev/stderr | grep 'dr-restore.sh snapshot' >/dev/null && [[ ! -e "$d" ]]; }   # no grep -q: SIGPIPE + pipefail
t  J02 "--dry-run prints every step + command and creates nothing (no evidence folder)" j02
tf J03 "DR_RUN_GATES=auto is refused outside the local test bed" "only for the local test bed" env DR_ENV=uat DR_RUN_GATES=auto "$RUN" S3
k patch secret app-db-direct --type merge -p '{"stringData":{"POSTGRES_DB_HOST1":"'"$IP_OLD"'","POSTGRES_DB_HOST2":"'"$IP_OLD"'"}}' >/dev/null
j04() { "${JENV[@]}" DR_ID="$JS3" RESTORED_DB="app-pg-local-r$JTS" "$RUN" S3; local rc=$? d; d="$(jdir "$JS3")"; echo "rc=$rc"
        (( rc == 0 )) && [[ "$(dhosts)" == "$IP_RESTORED,$IP_RESTORED" ]] \
        && [[ "$(jq -r '.marker' "$d/timeline.jsonl" | grep -E '^T(0|1|2|4|5|6|7|9|10)$' | sort -u | wc -l)" == 9 ]] \
        && [[ "$(grep -c '| PASS |' "$d/run-report.md")" == 19 ]] && grep -q '| P3-S01 | change | .* | NA |' "$d/run-report.md" \
        && ls "$d"/steps/P2-S04.log "$d"/approvals/P1-G1.txt "$d"/approvals/P3-G0.txt "$d"/approvals/P4-G4.txt >/dev/null \
        && grep -q 'RESULT .* VALIDATED' "$d/steps/P2-S04.log" && grep -q 'EVIDENCE_UPLOADED' "$d/timeline.jsonl" \
        && grep -q '📄 evidence' "$d/run.log" && [[ -z "$(find "$d/steps" -name '.*' -type f)" ]]; }
t  J04 "S3 end to end: 19 PASS + fence N/A, T0…T10, VALIDATED, both host keys → restored, approvals, step logs" j04
j05() { "${JENV[@]}" DR_ID="$JF" SNAPSHOT_ID=does-not-exist RESTORED_DB="app-pg-local-rf$JTS" "$RUN" S3 --on-fail continue --skip P0-S01,P0-S02 --to P3-S03
        local rc=$?; echo "rc=$rc"
        (( rc == 1 )) && [[ "$(jst "$JF" P1-S02)" == FAIL && "$(jst "$JF" P2-S01)" == BLOCKED && "$(jst "$JF" P3-S02)" == BLOCKED ]] \
        && ! grep -q '"marker":"T4"' "$(jdir "$JF")/timeline.jsonl" && [[ "$(dhosts)" == "$IP_RESTORED,$IP_RESTORED" ]]; }
t  J05 "a failed step BLOCKS what depends on it: bad snapshot → no restore, no cutover (--on-fail continue)" j05
k patch secret app-db-direct --type merge -p '{"stringData":{"POSTGRES_DB_HOST1":"'"$IP_OLD"'","POSTGRES_DB_HOST2":"'"$IP_OLD"'"}}' >/dev/null
j06() { "${JENV[@]}" DR_ID="$JS4" RESTORED_DB="app-pg-local-p$JTS" DR_RUN_AUTO_NO=P3A-G0 "$RUN" S4; local rc=$?; echo "rc=$rc"
        (( rc == 4 )) && [[ "$(jst "$JS4" P3A-G0)" == STOPPED ]] && [[ "$(dhosts)" == "$IP_OLD,$IP_OLD" ]] \
        && grep -q 'P3A-G0 NO by' "$(jdir "$JS4")/timeline.jsonl" && grep -q '"marker":"RPO_RESTORE_TS"' "$(jdir "$JS4")/timeline.jsonl"; }
t  J06 "S4 (mode A): NO at the cutover gate stops the run (exit 4), Secret untouched, decision recorded" j06
j07() { "${JENV[@]}" "$RUN" S4 --resume "$JS4" | tee "$LOGS/J07.out"; local rc=${PIPESTATUS[0]}; echo "rc=$rc"
        (( rc == 0 )) && grep -q 'P2-S01 .*done earlier (PASS)' "$LOGS/J07.out" && [[ "$(grep -c '"marker":"T4"' "$(jdir "$JS4")/timeline.jsonl")" == 1 ]] \
        && [[ "$(dhosts)" == "$IP_RESTORED,$IP_RESTORED" ]] && grep -q '"marker":"T10"' "$(jdir "$JS4")/timeline.jsonl"; }
t  J07 "--resume continues after the gate: passed steps not repeated (one T4), cutover + T10 done" j07
tf J08 "a second run with the same DR_ID without --resume is refused" "already has a run" "${JENV[@]}" DR_ID="$JS4" "$RUN" S4
j09() { local out id; out="$(env -u DR_ID "${JENV[@]:1}" RESTORED_DB=app-pg-local-rx "$RUN" S3 --only P0-S03)"; echo "$out"
        id="$(grep -oE 'DR_ID DR-[0-9]{8}-[0-9]{4}-local-S3' <<<"$out" | head -1 | cut -d' ' -f2)"; echo "id=$id"
        [[ -n "$id" ]] && [[ "$(jst "$id" P0-S03)" == PASS ]] && [[ -f "$(jdir "$id")/run.log" ]]; }
t  J09 "no DR_ID given: a new DR-<date>-local-S3 id + its own evidence folder" j09

echo; echo "PASS=$PASSN FAIL=$FAILN  (report: $REPORT, evidence: $DR_EVIDENCE_DIR)"
printf '\n**PASS=%s FAIL=%s** · DR_ID=%s · %s\n' "$PASSN" "$FAILN" "$DR_ID" "$(date -u +%FT%TZ)" >> "$REPORT"
exit "$FAILN"
