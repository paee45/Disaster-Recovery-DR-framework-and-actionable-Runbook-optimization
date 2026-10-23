#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
export HELPER="$HERE/bb3-prompt.sh" TEMP

cat > "$TEMP/probe.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$HELPER"
bb3_prompt_read answer 'Question? '
[[ "$answer" == reply ]]
bb3_prompt_token_read token 'Type ' GO ' to continue: '
[[ "$token" == GO ]]
EOF
export PROBE="$TEMP/probe.sh"

cat > "$TEMP/interactive.exp" <<'EOF'
set timeout 10
log_file -noappend $env(TEMP)/interactive.out
spawn bash $env(PROBE)
expect "Question? "
send "reply\r"
expect "Type "
expect "GO"
expect " to continue: "
send "GO\r"
expect eof
EOF

cat > "$TEMP/no-color.exp" <<'EOF'
set timeout 10
log_file -noappend $env(TEMP)/no-color.out
spawn env NO_COLOR= bash $env(PROBE)
expect "Question? "
send "reply\r"
expect "Type GO to continue: "
send "GO\r"
expect eof
EOF

expect -f "$TEMP/interactive.exp" >/dev/null
grep -F "$(printf '\033[1;33mQuestion? \033[0m')" "$TEMP/interactive.out" >/dev/null
grep -F "$(printf '\033[1;33mType \033[1;35mGO\033[1;33m to continue: \033[0m')" \
  "$TEMP/interactive.out" >/dev/null
expect -f "$TEMP/no-color.exp" >/dev/null
if LC_ALL=C grep -q "$(printf '\033')" "$TEMP/no-color.out"; then
  echo 'FAIL NO_COLOR left ANSI styling enabled' >&2
  exit 1
fi
sed -e 's/NO_COLOR= bash/TERM=dumb bash/' -e 's/no-color.out/term-dumb.out/' \
  "$TEMP/no-color.exp" > "$TEMP/term-dumb.exp"
expect -f "$TEMP/term-dumb.exp" >/dev/null
if LC_ALL=C grep -q "$(printf '\033')" "$TEMP/term-dumb.out"; then
  echo 'FAIL TERM=dumb left ANSI styling enabled' >&2
  exit 1
fi
echo 'PASS BB3 prompts style questions and required tokens; NO_COLOR disables ANSI'