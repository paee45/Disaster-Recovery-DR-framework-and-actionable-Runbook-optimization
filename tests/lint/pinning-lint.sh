#!/usr/bin/env bash
# pinning-lint.sh — fail if any aws/kubectl call in the DR scripts lacks an explicit --profile/--region/--context.
# Runs in CI (.github/workflows/dr-lint.yml) and as a pre-commit hook (.githooks/pre-commit). Static backstop for the
# runtime refusal in dr-lib.sh (DR_STRICT_PIN=1). A line can be exempted with a trailing "# pin-lint: ok <reason>".
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
files=("$@"); (( ${#files[@]} )) || mapfile -t files < <(ls "$ROOT"/automation/scripts/*.sh "$ROOT"/tests/aws/*.sh)
svc='(rds|sts|secretsmanager|s3api|s3|ssm|cloudwatch|cloudtrail|eks|ec2|logs|sns|kms|events|backup|iam|sso)'
verbs='(get|apply|delete|patch|rollout|wait|annotate|create|describe|logs|exec|label|scale|edit|replace|run|cp|port-forward|auth|top)'
bad=0
for f in "${files[@]}"; do
  while IFS= read -r hit; do
    n="${hit%%:*}"; line="${hit#*:}"
    [[ "$line" =~ ^[[:space:]]*# || "$line" == *"# pin-lint: ok"* ]] && continue
    if [[ "$line" =~ (^|[^[:alnum:]_./$-])aws\ +$svc([^[:alnum:]-]|$) ]]; then
      echo "UNPINNED aws (no --profile/--region before the service): ${f#"$ROOT"/}:$n: ${line#"${line%%[![:space:]]*}"}"; bad=$((bad+1)); fi
    if [[ "$line" =~ (^|[^[:alnum:]_./$-])kubectl\ +(-n\ +[^ ]+\ +)?$verbs([^[:alnum:]-]|$) ]]; then
      echo "UNPINNED kubectl (no --context before the verb): ${f#"$ROOT"/}:$n: ${line#"${line%%[![:space:]]*}"}"; bad=$((bad+1)); fi
    if [[ "$line" =~ command\ +aws\  && "$line" != *--profile* ]] || [[ "$line" =~ command\ +kubectl\ +$verbs && "$line" != *--context* ]]; then
      echo "UNPINNED direct binary call: ${f#"$ROOT"/}:$n: ${line#"${line%%[![:space:]]*}"}"; bad=$((bad+1)); fi
  done < <(grep -nE '(aws|kubectl) ' "$f")
done
(( bad == 0 )) && echo "pinning-lint: OK (${#files[@]} files)" || echo "pinning-lint: $bad unpinned call(s)"
exit $(( bad > 0 ))
