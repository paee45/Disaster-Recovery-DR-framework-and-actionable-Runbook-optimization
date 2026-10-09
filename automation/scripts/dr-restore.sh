#!/usr/bin/env bash
# dr-restore.sh — S3/S4 restore driven by a captured BASELINE of the source instance (TICKET-103).
# RDS restore defaults are unsafe (default VPC SG, default parameter group, backup retention 1 day, no deletion protection,
# no tags, no PI/monitoring, no IAM roles). So: capture everything the source has → build the restore from it → apply what
# a restore cannot set → validate EVERY setting against the baseline before the cutover.
#
#   capture <source-db>                          save the source config (describe + all tags + pg_settings) as a baseline file
#   plan snapshot <snapshot-id> <new-db-id>      print the restore request built from the baseline — no change
#   plan pitr <source-db> <new-db-id> <ts|latest>
#   list-snapshots <db-id>                       newest first + PITR window
#   snapshot <snapshot-id> <new-db-id>           restore a snapshot with every setting from the baseline
#   pitr <source-db> <new-db-id> <ISO8601|latest>
#   wait <new-db-id>                             wait until available, print elapsed time, dr_mark T5
#   harden <new-db-id>                           converge to the baseline: what restore cannot set (maintenance window, PI,
#                                                monitoring, max storage, IAM roles, missing tags) + re-assert retention,
#                                                backup window, deletion protection; reboot if the parameter group is
#                                                pending-reboot; then validate
#   validate <new-db-id>                         compare ALL settings with the baseline; exit 1 on any unexpected difference
#   create-like <source-db> <new-db-id>          EMPTY instance with the source's configuration (a test primary for
#                                                local/dev/uat); master password managed by RDS in Secrets Manager
#   validate-pg                                  compare pg_settings of TARGET_DSN with the source (live OLD_DSN, else baseline)
#
# Baseline resolution (restore/harden/validate): BASELINE_FILE if set → else capture live from the source if it still
# exists (and report drift vs the last stored capture) → else the last stored capture $BASELINE_DIR/baseline-<src>.json
# (or $BASELINE_S3_URI). Capture on a schedule so a baseline exists when the source is gone (docs/11 §baseline).
# Optional overrides in env/<env>.env (empty = baseline): DB_INSTANCE_CLASS DB_SUBNET_GROUP DB_SG (space separated)
# DB_PARAM_GROUP. Policy floors: BACKUP_RETENTION_DAYS (minimum, default 7), MULTI_AZ=true (force), deletion protection
# outside dev. EXTRA_TAGS="Key=k,Value=v ..." are added. DRY_RUN=1 prints the requests only.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=dr-lib.sh
source "$HERE/dr-lib.sh"
dr_guard || exit 1
: "${DR_ENV:?}"
BASELINE_DIR="${BASELINE_DIR:-$ROOT/evidence/baselines/$DR_ENV}"
OUT="${DR_EVIDENCE_DIR:-$ROOT/evidence/adhoc}/aws"; mkdir -p "$BASELINE_DIR" "$OUT"
RET_FLOOR="${BACKUP_RETENTION_DAYS:-7}"
[[ -n "$RET_FLOOR" ]] || RET_FLOOR=7

# ---------- jq library shared by plan / restore / harden / validate ----------
JQLIB="$(cat "$HERE/rds-requests.jq")"          # shared request builders (also used by tests/local/up.sh)

# ---------- baseline ----------
capture() { # <source-db> → prints the file path
  local src="$1" ts inst arn tags pg="{}" dsn f
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  inst="$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-instances --db-instance-identifier "$src" --query 'DBInstances[0]' --output json)"
  arn="$(jq -r .DBInstanceArn <<<"$inst")"
  tags="$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds list-tags-for-resource --resource-name "$arn" --query TagList --output json 2>/dev/null || jq -c '.TagList // []' <<<"$inst")"
  if dsn="$(dr_dsn "$src" 2>/dev/null)" && [[ -n "$dsn" ]]; then     # pg_settings as the DB actually runs them (best effort)
    pg="$(psql "$dsn" -XAtq -F$'\t' -c 'select name, setting from pg_settings order by 1' 2>/dev/null \
          | jq -Rn '[inputs | split("\t") | {key: .[0], value: .[1]}] | from_entries' 2>/dev/null)" || pg="{}"   # a failed psql must not leave two JSON values
  fi
  f="$BASELINE_DIR/baseline-${src}-${ts}.json"
  jq -n --argjson i "$inst" --argjson t "$tags" --argjson pg "$pg" --arg src "$src" --arg env "$DR_ENV" \
        --arg acct "${ACCOUNT_ID:-}" --arg region "${AWS_REGION:-}" --arg at "$(date -u +%FT%TZ)" --arg by "${DR_ACTOR:-$(_dr_actor)}" \
    '{capturedAt: $at, capturedBy: $by, env: $env, account: $acct, region: $region, source: $src,
      instance: $i, tags: $t, pgSettings: $pg}' > "$f"
  cp "$f" "$BASELINE_DIR/baseline-${src}.json"
  [[ -n "${DR_EVIDENCE_DIR:-}" ]] && cp "$f" "$OUT/" || true
  [[ -n "${BASELINE_S3_URI:-}" ]] && aws --profile "$AWS_PROFILE" --region "$AWS_REGION" s3 cp --only-show-errors "$f" "${BASELINE_S3_URI%/}/baseline-${src}.json" || true
  echo "$f"
}

summary() { # <baseline-file>
  jq -r '.instance as $i | "baseline \(.source) captured \(.capturedAt): class=\($i.DBInstanceClass) engine=\($i.Engine) \($i.EngineVersion) multiAZ=\($i.MultiAZ) subnets=\($i.DBSubnetGroup.DBSubnetGroupName) sgs=[\([$i.VpcSecurityGroups[].VpcSecurityGroupId] | join(" "))] pg=\($i.DBParameterGroups[0].DBParameterGroupName) og=\($i.OptionGroupMemberships[0].OptionGroupName // "-") retention=\($i.BackupRetentionPeriod)d tags=\(.tags | length) roles=\($i.AssociatedRoles // [] | length) pgSettings=\(.pgSettings | length)"' "$1"
}

load_baseline() { # <source-db> → sets BASE (file)
  local src="$1" stored="$BASELINE_DIR/baseline-${1}.json" prev=""
  if [[ -n "${BASELINE_FILE:-}" ]]; then
    BASE="$BASELINE_FILE"; echo "baseline: $BASE (BASELINE_FILE)"
  elif aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-instances --db-instance-identifier "$src" >/dev/null 2>&1; then
    [[ -f "$stored" ]] && { prev="$(mktemp)"; cp "$stored" "$prev"; }
    BASE="$(capture "$src")"; echo "baseline: captured live from $src → $BASE"
    if [[ -n "$prev" ]]; then   # drift since the last capture = something changed on the source (incident? manual change?)
      local d; d="$(jq -rn --slurpfile a "$prev" --slurpfile b "$BASE" "$JQLIB"'
        ($a[0].instance | norm) as $x | ($b[0].instance | norm) as $y
        | ([$x, $y] | map(keys) | add | unique)[] as $k | select(($x[$k] | tojson) != ($y[$k] | tojson))
        | "  DRIFT \($k): last capture \($a[0].capturedAt)=\($x[$k] | tojson) → now \($y[$k] | tojson)"')"
      [[ -n "$d" ]] && { echo "WARN source changed since the last stored capture (check it is not incident damage):"; echo "$d"; }
      rm -f "$prev"
    fi
  else
    [[ -f "$stored" || -z "${BASELINE_S3_URI:-}" ]] || aws --profile "$AWS_PROFILE" --region "$AWS_REGION" s3 cp --only-show-errors "${BASELINE_S3_URI%/}/baseline-${src}.json" "$stored" || true
    [[ -f "$stored" ]] || { echo "FAIL source $src is gone and no stored baseline ($stored) — set BASELINE_FILE, or DB_* in env/$DR_ENV.env"; exit 1; }
    BASE="$stored"; echo "WARN source $src not found — using the stored baseline captured $(jq -r .capturedAt "$BASE")"
  fi
  summary "$BASE"
}

overrides() { # JSON of explicit env overrides (empty values = take the baseline)
  jq -n --arg c "${DB_INSTANCE_CLASS:-}" --arg s "${DB_SUBNET_GROUP:-}" --arg g "${DB_SG:-}" --arg p "${DB_PARAM_GROUP:-}" \
    '{class: $c, subnets: $s, sgs: ($g | split(" ") | map(select(. != ""))), pg: $p}
     | with_entries(select(.value != "" and .value != []))'
}

expected_json() { # baseline instance with overrides + policy floors applied
  local maz=false; [[ "${MULTI_AZ:-}" == "true" ]] && maz=true
  jq --argjson ov "$(overrides)" --arg env "$DR_ENV" --argjson floor "$RET_FLOOR" --argjson maz "$maz" \
     "$JQLIB"'.instance | expected($ov; $env; $floor; $maz)' "$BASE"
}

wanted_tags() { # <restored-from> → JSON tag list: baseline tags (minus aws:*) + EXTRA_TAGS + dr-restore markers
  local extra; extra="$(tr ' ' '\n' <<<"${EXTRA_TAGS:-}" | sed -nE 's/^Key=([^,]+),Value=(.*)$/{"Key":"\1","Value":"\2"}/p' | jq -s .)"
  jq --argjson extra "$extra" --arg id "${DR_ID:-manual}" --arg from "$1" "$JQLIB"'
    (.tags | userTags) + $extra + [{Key: "dr-restore", Value: $id}, {Key: "dr-restored-from", Value: $from}]
    | reduce .[] as $t ({}; .[$t.Key] = $t.Value) | to_entries | map({Key: .key, Value: .value})' "$BASE"
}

# restore request (shared part) — every setting the Restore* APIs accept, from the expected baseline
restore_request() { # <op-specific-json> <restored-from>
  jq -S --argjson op "$1" --argjson tags "$(wanted_tags "$2")" "$JQLIB"' restore_req($op; $tags)' <<<"$(expected_json)"
}

run_request() { # <api-op> <request-file> <description>
  echo "request ($3) → $2"; jq . "$2"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then echo "DRY_RUN: aws --profile $AWS_PROFILE --region $AWS_REGION rds $1 --cli-input-json file://$2"; return 0; fi
  dr_confirm "$3" || exit 1
  aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds "$1" --cli-input-json "file://$2" \
    --query 'DBInstance.{id:DBInstanceIdentifier,status:DBInstanceStatus,multiAZ:MultiAZ,retention:BackupRetentionPeriod}' --output table
  [[ -n "${DR_TIMELINE:-}" ]] && dr_mark T4 "restore started: $3 (request $(basename "$2"))" || true
}

describe() { aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-instances --db-instance-identifier "$1" --query 'DBInstances[0]' --output json; }

wait_available() {
  local db="$1" start now st miss=0
  start=$(date +%s)
  while :; do
    st="$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-instances --db-instance-identifier "$db" --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo not-found)"
    now=$(date +%s)
    printf '%s  %-12s elapsed %dm%02ds\n' "$(date -u +%H:%M:%SZ)" "$st" $(( (now-start)/60 )) $(( (now-start)%60 ))
    [[ "$st" == "available" ]] && break
    [[ "$st" == failed || "$st" == incompatible-* || "$st" == storage-full ]] && { echo "FAIL $db status $st — see CP-07"; return 1; }
    if [[ "$st" == not-found ]] && ! dr_auth_ok; then      # logged out mid-wait (SSO expiry) is not "instance missing"
      dr_reauth || { echo "FAIL AWS credentials expired during the wait. The restore keeps running — log in again, then: $0 wait $db"; return 1; }
      miss=0; continue
    fi
    if [[ "$st" == not-found ]]; then miss=$((miss+1)); (( miss < ${WAIT_NOTFOUND_MAX:-10} )) || { echo "FAIL $db does not exist (did the restore call fail?)"; return 1; }; fi
    sleep "${WAIT_POLL_S:-30}"
  done
  [[ -n "${DR_TIMELINE:-}" ]] && dr_mark T5 "$db available after $(( (now-start)/60 ))m$(( (now-start)%60 ))s" || true
}

# baseline source of a restored instance: its dr-restored-from tag ("<db>" or "<db>@<snapshot|ts>"), else SOURCE_DB/PRIMARY_DB
source_of() {
  local from; from="$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds list-tags-for-resource --resource-name "$(describe "$1" | jq -r .DBInstanceArn)" \
    --query "TagList[?Key=='dr-restored-from'].Value | [0]" --output text 2>/dev/null || true)"
  [[ -n "$from" && "$from" != "None" ]] && echo "${from%%@*}" || echo "${SOURCE_DB:-${PRIMARY_DB:?}}"
}

harden() {
  local db="$1" t e mod req roles tags arn warn
  t="$(describe "$db")"; e="$(expected_json)"
  # Modify request: only attributes that differ from the expected baseline (converge, don't churn).
  mod="$(jq -S --argjson t "$t" --arg db "$db" "$JQLIB"' harden_req($t; $db)' <<<"$e")"
  req="$OUT/harden-request-${db}.json"; echo "$mod" > "$req"
  if [[ "$mod" == "{}" ]]; then echo "harden: no setting differs from the baseline"
  else
    echo "harden: modify request (only differing settings) → $req"; jq . "$req"
    # The baseline is the live source as captured now; where the snapshot disagrees, the baseline wins and the change is logged.
    warn="$(jq -r --argjson t "$t" 'to_entries[] | select(.key | IN("DBInstanceIdentifier", "ApplyImmediately") | not)
        | "  \(.key): restored instance \($t[.key] // "(see request)" | tojson)  →  baseline \(.value | tojson)"' <<<"$mod")"
    { echo "WARN harden: $(grep -c . <<<"$warn") setting(s) of $db differ from the CURRENT baseline of ${SOURCE_DB:-$PRIMARY_DB}"
      echo "     (changed on the source after the snapshot was taken, or not carried by the restore); the baseline is applied:"
      echo "$warn"; } | tee "$OUT/harden-diff-${db}.txt"
    [[ -n "${DR_TIMELINE:-}" ]] && dr_mark HARDEN_DIFF "$(jq -c 'keys - ["DBInstanceIdentifier", "ApplyImmediately"]' <<<"$mod") applied from the current baseline" || true
    [[ "${DRY_RUN:-0}" == "1" ]] || aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds modify-db-instance --cli-input-json "file://$req" --query 'DBInstance.PendingModifiedValues' --output json
  fi
  # IAM roles (S3 import/export, Lambda, …) — not carried by a restore
  roles="$(jq -c --argjson t "$t" '[.AssociatedRoles[]? | {RoleArn, FeatureName}] - [$t.AssociatedRoles[]? | {RoleArn, FeatureName}] | .[]' <<<"$e")"
  while read -r r; do
    [[ -z "$r" ]] && continue
    echo "+ add-role-to-db-instance $r"
    [[ "${DRY_RUN:-0}" == "1" ]] || aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds add-role-to-db-instance --db-instance-identifier "$db" \
      --role-arn "$(jq -r .RoleArn <<<"$r")" --feature-name "$(jq -r .FeatureName <<<"$r")"
  done <<<"$roles"
  # Tags missing or different on the target (restore normally copies them; re-assert anyway)
  arn="$(jq -r .DBInstanceArn <<<"$t")"
  tags="$(jq -c --argjson have "$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds list-tags-for-resource --resource-name "$arn" --query TagList --output json)" "$JQLIB"'
           (.tags | userTags) - $have' "$BASE")"
  if [[ "$tags" != "[]" ]]; then
    echo "WARN harden: tags missing on $db compared with the current baseline, added: $(jq -c 'map(.Key)' <<<"$tags")"
    echo "+ add-tags-to-resource $(jq -c 'map(.Key)' <<<"$tags")"
    [[ "${DRY_RUN:-0}" == "1" ]] || aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds add-tags-to-resource --resource-name "$arn" --tags "$tags"
  fi
  [[ "${DRY_RUN:-0}" == "1" ]] && return 0
  sleep "${HARDEN_SETTLE_S:-20}"; wait_available "$db" >/dev/null
  # A parameter group change (or the restore itself) can leave static parameters pending-reboot → reboot now, before cutover
  if [[ "$(describe "$db" | jq -r '[.DBParameterGroups[].ParameterApplyStatus] | index("pending-reboot") != null')" == "true" ]]; then
    echo "parameter group is pending-reboot → reboot-db-instance $db (not yet in service)"
    aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds reboot-db-instance --db-instance-identifier "$db" --query 'DBInstance.DBInstanceStatus' --output text
    sleep "${HARDEN_SETTLE_S:-20}"; wait_available "$db" >/dev/null
  fi
  validate "$db"
}

validate() { # <db> — exit 1 on unexpected differences
  local db="$1" t report rc=0; report="$OUT/validate-${db}.txt"
  t="$(describe "$db")"
  {
    echo "validate $db against baseline $(jq -r '"\(.source) captured \(.capturedAt)"' "$BASE")  ($(date -u +%FT%TZ))"
    jq -rn --argjson t "$t" --argjson e "$(expected_json)" --slurpfile b "$BASE" \
           --argjson have "$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds list-tags-for-resource --resource-name "$(jq -r .DBInstanceArn <<<"$t")" --query TagList --output json)" "$JQLIB"'
      ($b[0].instance | norm) as $base | ($e | norm) as $x | ($t | norm) as $y
      | ([$x | keys[] | select(($x[.] | tojson) == ($y[.] | tojson))] | length) as $match
      | ([$x | keys[] | select(($x[.] | tojson) != ($y[.] | tojson))
          | "DIFF    \(.): expected \($x[.] | tojson)  actual \($y[.] | tojson)"
            + (if ($base[.] | tojson) != ($x[.] | tojson) then "  (baseline \($base[.] | tojson))" else "" end)]) as $diff
      | ([$x | keys[] | select(($base[.] | tojson) != ($x[.] | tojson) and ($x[.] | tojson) == ($y[.] | tojson))
          | "POLICY  \(.): \($y[.] | tojson)  (baseline \($base[.] | tojson); override/policy floor)"]) as $pol
      | ([$y | keys[] | select(. as $k | $x | has($k) | not) | "INFO    \(.)=\($y[.] | tojson) (not in baseline, not compared)"]) as $extra
      | ([($b[0].tags | userTags)[] as $w | select([$have[] | select(.Key == $w.Key and .Value == $w.Value)] | length == 0)
          | "DIFF    tag \($w.Key): expected \($w.Value | tojson)  actual \(([$have[] | select(.Key == $w.Key) | .Value][0] // "<missing>") | tojson)"]) as $tagdiff
      | ([$t.PendingModifiedValues // {} | to_entries[] | "DIFF    pending modification \(.key)=\(.value | tojson) (not applied yet)"]) as $pend
      | ([$t.DBInstanceStatus | select(. != "available") | "DIFF    status \(.) (expected available)"]) as $st
      | ($diff + $tagdiff + $pend + $st) as $all
      | ($pol + $extra)[], $all[],
        (if ($b[0].instance.UpgradeRolloutOrder // null) != ($t.UpgradeRolloutOrder // null) then
           "INFO    UpgradeRolloutOrder: source \($b[0].instance.UpgradeRolloutOrder | tojson), target \($t.UpgradeRolloutOrder | tojson) — not settable by the API, not compared" else empty end),
        (if ($b[0].instance.StorageEncrypted // false) == false then
           "NOTE    source is NOT encrypted at rest — snapshots/restores inherit it (ISO 27001 A.8.24). Fix: copy-db-snapshot --kms-key-id …, restore the encrypted copy" else empty end),
        (if ($b[0].instance.ReadReplicaDBInstanceIdentifiers // []) != [] then
           "NOTE    source had read replica(s) \($b[0].instance.ReadReplicaDBInstanceIdentifiers | join(",")) — a restore does not recreate them (runbook failback/rebuild step)" else empty end),
        "RESULT  \($match) settings match, \(($b[0].tags | userTags) | length) tags checked, \($all | length) unexpected difference(s) → \(if ($all | length) == 0 then "VALIDATED" else "NOT VALIDATED" end)"'
  } | tee "$report"
  grep -q '^RESULT .*→ VALIDATED$' "$report" || rc=1
  [[ -n "${DR_TIMELINE:-}" ]] && dr_mark RESTORE_VALIDATE "$db rc=$rc $(tail -1 "$report")" >/dev/null || true
  return "$rc"
}

validate_pg() { # TARGET_DSN vs live OLD_DSN (else the baseline's pgSettings)
  : "${TARGET_DSN:?run dr_set_target <db> first}"
  local q='select name, setting from pg_settings order by 1' ref src cur report="$OUT/validate-pg-${TARGET_DB:-target}.txt"
  local ign="^(data_directory|hba_file|ident_file|config_file|external_pid_file|listen_addresses|application_name|transaction_.*|default_transaction_read_only|in_hot_standby|ssl_.*_file|krb_server_keyfile|log_directory)$"
  [[ -n "${PG_VALIDATE_IGNORE:-}" ]] && ign="${ign%)\$}|${PG_VALIDATE_IGNORE})\$"
  tojs() { jq -Rn '[inputs | split("\t") | {key: .[0], value: .[1]}] | from_entries'; }
  cur="$(psql "$TARGET_DSN" -XAtq -F$'\t' -c "$q" | tojs)"
  if [[ -n "${OLD_DSN:-}" ]] && ref="$(psql "$OLD_DSN" -XAtq -F$'\t' -c "$q" 2>/dev/null | tojs)" && [[ "$ref" != "{}" ]]; then src="live ${OLD_DB:-source}"
  else ref="$(jq '.pgSettings // {}' "$BASE")"; src="baseline $(jq -r .capturedAt "$BASE")"; fi
  # exit 3 = N/A (not a failure): nothing to compare against, e.g. the source is intentionally stopped
  [[ "$ref" == "{}" ]] && { echo "N/A: no reference pg_settings (source unreachable/stopped and the baseline has none) — validate-pg not performed"; return 3; }
  jq -rn --argjson r "$ref" --argjson c "$cur" --arg ign "$ign" --arg src "$src" '
    ([$r | keys[] | select(test($ign) | not)]) as $k
    | ([$k[] | select($r[.] != $c[.]) | "DIFF    \(.): source \($r[.] | tojson)  target \($c[.] | tojson)"]) as $d
    | "pg_settings: target vs \($src)", $d[], "RESULT  \($k | length) settings compared, \($d | length) difference(s) → \(if ($d | length) == 0 then "VALIDATED" else "NOT VALIDATED" end)"' \
    | tee "$report"
  grep -q '→ VALIDATED$' "$report"
}

# ---------- restore commands ----------
cmd_snapshot() { # <snap> <new>
  local snap="$1" new="$2" sj src created size op req
  sj="$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-snapshots --db-snapshot-identifier "$snap" --query 'DBSnapshots[0]' --output json)"
  src="$(jq -r '.DBInstanceIdentifier // empty' <<<"$sj")"; src="${SOURCE_DB:-${src:-${PRIMARY_DB:?}}}"
  created="$(jq -r '.SnapshotCreateTime // "unknown"' <<<"$sj")"; size="$(jq -r '.AllocatedStorage // 0' <<<"$sj")"
  load_baseline "$src"
  echo "snapshot $snap created $created  → RPO reference point (recorded as RPO_SNAPSHOT)"
  [[ -n "${DR_TIMELINE:-}" && "$created" != "unknown" && "${DRY_RUN:-0}" != "1" ]] && dr_mark RPO_SNAPSHOT "value=$created"
  # storage: the snapshot size unless the source has grown since (restore straight to the baseline size)
  op="$(jq -n --arg new "$new" --arg snap "$snap" --argjson size "$size" --argjson b "$(jq .instance "$BASE")" \
        '{DBInstanceIdentifier: $new, DBSnapshotIdentifier: $snap}
         + (if ($b.AllocatedStorage // 0) > $size then {AllocatedStorage: $b.AllocatedStorage} else {} end)')"
  req="$OUT/restore-request-${new}.json"; restore_request "$op" "$src@$snap" > "$req"
  run_request restore-db-instance-from-db-snapshot "$req" "restore $snap → $new"
}

cmd_create_like() { # <source-db> <new-db> — EMPTY instance with the source's configuration (test primary)
  local src="$1" new="$2" req
  load_baseline "$src"
  req="$OUT/create-request-${new}.json"
  # CREATE_OVERRIDES='{"MasterUserPassword":"…"}' (local tests) — default: RDS-managed master password in Secrets Manager
  jq -S --arg id "$new" --argjson tags "$(wanted_tags "$src@create-like")" --argjson ov "${CREATE_OVERRIDES:-{\}}" \
     "$JQLIB"' create_req($id; $tags; $ov)' <<<"$(expected_json)" > "$req"
  run_request create-db-instance "$req" "create $new like $src (empty, same configuration)"
}

cmd_pitr() { # <src> <new> <ts|latest>
  local src="$1" new="$2" ts="$3" op req s t
  load_baseline "$src"
  [[ -n "${DR_TIMELINE:-}" && "$ts" != "latest" && "${DRY_RUN:-0}" != "1" ]] && dr_mark RPO_RESTORE_TS "value=$ts"
  if aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-instances --db-instance-identifier "$src" >/dev/null 2>&1; then
    s="$(jq -n --arg s "$src" '{SourceDBInstanceIdentifier: $s}')"
  else  # source deleted → retained automated backups
    s="$(jq -n --arg r "$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-instance-automated-backups --db-instance-identifier "$src" --query 'DBInstanceAutomatedBackups[0].DbiResourceId' --output text)" '{SourceDbiResourceId: $r}')"
  fi
  if [[ "$ts" == "latest" ]]; then t='{"UseLatestRestorableTime": true}'; else t="$(jq -n --arg ts "$ts" '{RestoreTime: $ts}')"; fi
  op="$(jq -n --arg new "$new" --argjson s "$s" --argjson t "$t" --argjson b "$(jq .instance "$BASE")" \
        '{TargetDBInstanceIdentifier: $new} + $s + $t
         + ({AllocatedStorage: $b.AllocatedStorage, MaxAllocatedStorage: $b.MaxAllocatedStorage} | with_entries(select(.value != null)))')"
  req="$OUT/restore-request-${new}.json"; restore_request "$op" "$src@$ts" > "$req"
  run_request restore-db-instance-to-point-in-time "$req" "PITR $src → $new at $ts"
}

case "${1:-}" in
  capture)        f="$(capture "${2:?source db id}")"; echo "baseline written: $f"; summary "$f" ;;
  plan)           shift; export DRY_RUN=1
                  case "${1:-}" in snapshot) cmd_snapshot "${2:?snapshot}" "${3:?new db}" ;;
                                   pitr) cmd_pitr "${2:?source}" "${3:?new db}" "${4:?ts|latest}" ;;
                                   create-like) cmd_create_like "${2:?source}" "${3:?new db}" ;;
                                   *) echo "usage: $0 plan {snapshot <snap> <new>|pitr <src> <new> <ts|latest>}"; exit 2 ;; esac ;;
  list-snapshots)
    db="${2:?db id}"
    aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-snapshots --db-instance-identifier "$db" --include-shared \
      --query 'reverse(sort_by(DBSnapshots,&SnapshotCreateTime))[].[DBSnapshotIdentifier,SnapshotType,SnapshotCreateTime,Status,Encrypted,AllocatedStorage]' \
      --output table
    echo "PITR window:"
    aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-instance-automated-backups --db-instance-identifier "$db" \
      --query 'DBInstanceAutomatedBackups[].{status:Status,window:RestoreWindow,resourceId:DbiResourceId}' --output table || true
    echo "stored baselines:"
    # shellcheck disable=SC2012
    ls -1t "$BASELINE_DIR"/baseline-"$db"-*.json 2>/dev/null | head -3 || echo "  none — run: $0 capture $db"
    ;;
  snapshot)       cmd_snapshot "${2:?snapshot id}" "${3:?new db id}" ;;
  pitr)           cmd_pitr "${2:?source db id}" "${3:?new db id}" "${4:?restore time or latest}" ;;
  create-like)    cmd_create_like "${2:?source db id}" "${3:?new db id}" ;;
  wait)           wait_available "${2:?db id}" ;;
  harden)         db="${2:?db id}"; dr_confirm "harden $db" || exit 1
                  BASELINE_FILE="${BASELINE_FILE:-$BASELINE_DIR/baseline-$(source_of "$db").json}"; BASE="$BASELINE_FILE"
                  [[ -f "$BASE" ]] || { echo "FAIL no baseline $BASE — run: $0 capture <source>"; exit 1; }
                  summary "$BASE"; harden "$db" ;;
  validate)       db="${2:?db id}"
                  BASE="${BASELINE_FILE:-$BASELINE_DIR/baseline-$(source_of "$db").json}"
                  [[ -f "$BASE" ]] || { echo "FAIL no baseline $BASE — run: $0 capture <source>"; exit 1; }
                  validate "$db" ;;
  validate-pg)    BASE="${BASELINE_FILE:-$BASELINE_DIR/baseline-${OLD_DB:-${PRIMARY_DB:?}}.json}"; validate_pg ;;
  *) sed -n '2,25p' "$0"; exit 2 ;;
esac
