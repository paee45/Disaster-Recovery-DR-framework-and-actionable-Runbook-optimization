#!/usr/bin/env bash
# dr-session.sh — start a RECORDED DR working shell. Everything typed and printed is captured as evidence.
#
#   automation/scripts/dr-session.sh env/uat.env S3            # new DR_ID
#   DR_ID=DR-20261004-0930-uat-S3 automation/scripts/dr-session.sh env/uat.env S3   # join / resume an event
#
# In the shell: env + dr-lib.sh are loaded (strict pinning, guard passed), dr_init done, prompt shows env/context.
# Captured under evidence/<DR_ID>/terminal/:
#   session-<ts>-<user>.log      full terminal transcript (script(1)), secrets redacted on exit
#   history-<user>.txt           every command with a UTC timestamp
# plus evidence/<DR_ID>/commands.jsonl (every aws/kubectl call: args redacted, rc, duration) and timeline.jsonl.
# On exit the evidence folder is synced to s3://$EVIDENCE_BUCKET/<env>/<year>/<DR_ID>/ (also at every dr_phase end).
set -euo pipefail
ENV_FILE="${1:?env file, e.g. env/uat.env}"; SCENARIO="${2:?scenario, e.g. S3}"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$ENV_FILE"
# shellcheck source=dr-lib.sh
source "$HERE/dr-lib.sh"
dr_init "$SCENARIO" >/dev/null || exit 1
T="$DR_EVIDENCE_DIR/terminal"; mkdir -p "$T"; chmod 700 "$T"
WHO="${USER:-$(id -un)}"; TS="$(date -u +%Y%m%dT%H%M%SZ)"
RAW="$T/session-$TS-$WHO.raw"; LOG="$T/session-$TS-$WHO.log"
RC="$(mktemp)"; trap 'rm -f "$RC"' EXIT
cat > "$RC" <<RCF
source "$(cd "$(dirname "$ENV_FILE")" && pwd)/$(basename "$ENV_FILE")"
source "$HERE/dr-lib.sh"
export DR_ID="$DR_ID" DR_SCENARIO="$DR_SCENARIO" DR_EVIDENCE_DIR="$DR_EVIDENCE_DIR" DR_TIMELINE="$DR_TIMELINE" DR_ACTOR="$DR_ACTOR"
export HISTFILE="$T/history-$WHO.txt" HISTTIMEFORMAT='%FT%TZ ' HISTSIZE=100000 HISTFILESIZE=100000 TZ=UTC
shopt -s histappend; PROMPT_COMMAND='history -a'
PS1='\[\e[1;$([[ "$DR_ENV" == prod ]] && echo 41 || echo 44)m\] $DR_ENV \[\e[0m\] $AWS_PROFILE ⎈ $EKS_CONTEXT [$DR_ID] \w \$ '
echo "Recorded DR shell — env=$DR_ENV profile=$AWS_PROFILE context=$EKS_CONTEXT strict=$DR_STRICT_PIN · evidence: $DR_EVIDENCE_DIR · exit to finish"
RCF
dr_mark SESSION_START "user=$WHO transcript=terminal/$(basename "$LOG")" >/dev/null
if [[ "$(uname -s)" == Darwin ]]; then script -q -F "$RAW" "$BASH" --rcfile "$RC" -i
else script -q -f -e -c "$BASH --rcfile $RC -i" "$RAW"; fi || true
# transcript: strip terminal control codes, redact secrets, drop the raw file (never leaves the machine)
sed -E 's/\x1b\[[0-9;?]*[ -\/]*[@-~]//g; s/\x1b\][^\x07]*\x07//g' "$RAW" | tr -d '\000-\010\013-\037' > "$LOG" && rm -f "$RAW"
dr_redact "$LOG"; [[ -f "$T/history-$WHO.txt" ]] && dr_redact "$T/history-$WHO.txt"
chmod 600 "$LOG"
dr_mark SESSION_END "user=$WHO lines=$(wc -l < "$LOG")" >/dev/null
dr_sync_evidence
echo "session saved: $LOG"
