#!/usr/bin/env bash

if [[ -t 0 && -t 1 && -z "${NO_COLOR+x}" && "${TERM:-dumb}" != dumb ]]; then
  BB3_PROMPT_YELLOW=$'\033[1;33m'
  BB3_PROMPT_MAGENTA=$'\033[1;35m'
  BB3_PROMPT_RESET=$'\033[0m'
else
  BB3_PROMPT_YELLOW=''
  BB3_PROMPT_MAGENTA=''
  BB3_PROMPT_RESET=''
fi

bb3_prompt_read() {
  local bb3_prompt_variable="$1" bb3_prompt_text="$2"
  printf '%s%s%s' "$BB3_PROMPT_YELLOW" "$bb3_prompt_text" "$BB3_PROMPT_RESET" >&2
  IFS= read -r "${bb3_prompt_variable?}"
}

bb3_prompt_token_read() {
  local bb3_prompt_variable="$1" bb3_prompt_before="$2" bb3_prompt_token="$3" bb3_prompt_after="$4"
  printf '%s%s%s%s%s%s' \
    "$BB3_PROMPT_YELLOW" "$bb3_prompt_before" \
    "$BB3_PROMPT_MAGENTA" "$bb3_prompt_token" \
    "$BB3_PROMPT_YELLOW" "$bb3_prompt_after$BB3_PROMPT_RESET" >&2
  IFS= read -r "${bb3_prompt_variable?}"
}

bb3_wait() {
  local helper_directory
  helper_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  python3 "$helper_directory/bb3-wait.py" "$@"
}