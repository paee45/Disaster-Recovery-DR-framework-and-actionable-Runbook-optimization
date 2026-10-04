#!/usr/bin/env bash
# dr-env-check.sh — validate the environment profile BEFORE starting a runbook (TICKET-103).
# Catches: unset/placeholder variables, wrong kube context, missing secrets/instances, missing tools.
# Usage: source env/<env>.env && ./automation/scripts/dr-env-check.sh [S1|S2|S3|S4]
set -uo pipefail
SC="${1:-S3}"
fails=0
ok()   { printf 'OK    %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; fails=$((fails+1)); }
warn() { printf 'WARN  %s\n' "$*"; }

for t in aws jq psql kubectl python3; do command -v "$t" >/dev/null && ok "tool $t" || bad "tool $t missing"; done

req=(DR_ENV AWS_PROFILE AWS_REGION ACCOUNT_ID PRIMARY_DB DB_NAME SECRET_ID EKS_CONTEXT K8S_NS K8S_SECRET EVIDENCE_BUCKET RTO_TARGET_MIN RPO_TARGET_S)
[[ "$SC" == "S2" ]] && req+=(REPLICA_DB)
[[ "$SC" == "S3" || "$SC" == "S4" ]] && req+=(MASTER_SECRET_ID)
for v in "${req[@]}"; do
  val="${!v:-}"
  if [[ -z "$val" ]]; then bad "$v is not set"
  elif [[ "$val" == *"{{"* || "$val" == *"<"*">"* || "$val" == *"TODO"* ]]; then bad "$v contains a placeholder: $val"
  else ok "$v=$val"; fi
done
[[ -n "${K8S_HOST_KEY:-}" ]] && ok "K8S_HOST_KEY=$K8S_HOST_KEY" || warn "K8S_HOST_KEY not set (default DB_HOST)"
[[ -n "${VERIFY_TABLES:-}" ]] && ok "VERIFY_TABLES set" || warn "VERIFY_TABLES empty — compare-counts unavailable"

if [[ -z "${AWS_PROFILE:-}" || -z "${EKS_CONTEXT:-}" ]]; then echo "ENV CHECK: FAIL — AWS_PROFILE and EKS_CONTEXT are mandatory"; exit 1; fi
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=dr-lib.sh
source "$HERE/dr-lib.sh"             # pins aws → $AWS_PROFILE/$AWS_REGION and kubectl → $EKS_CONTEXT
unset DR_GUARD_OK
if dr_guard; then ok "identity guard (account, cluster identity, context)"; else bad "identity guard — see GUARD FAIL above"; fi
aws rds describe-db-instances --db-instance-identifier "$PRIMARY_DB" >/dev/null 2>&1 && ok "instance $PRIMARY_DB exists" || warn "instance $PRIMARY_DB not found (expected if it was lost/deleted)"
[[ -n "${REPLICA_DB:-}" ]] && { aws rds describe-db-instances --db-instance-identifier "$REPLICA_DB" >/dev/null 2>&1 && ok "replica $REPLICA_DB exists" || bad "replica $REPLICA_DB not found"; }
aws secretsmanager describe-secret --secret-id "$SECRET_ID" >/dev/null 2>&1 && ok "secret $SECRET_ID readable" || bad "secret $SECRET_ID not readable"
kubectl config get-contexts -o name 2>/dev/null | grep -qx "$EKS_CONTEXT" && ok "kube context $EKS_CONTEXT present" || bad "kube context $EKS_CONTEXT missing (aws eks update-kubeconfig --name <cluster> --alias $EKS_CONTEXT)"
kubectl --context "$EKS_CONTEXT" -n "$K8S_NS" get secret "$K8S_SECRET" >/dev/null 2>&1 && ok "K8s secret $K8S_NS/$K8S_SECRET" || bad "K8s secret $K8S_NS/$K8S_SECRET not found"

echo "----"
(( fails == 0 )) && { echo "ENV CHECK: PASS"; exit 0; } || { echo "ENV CHECK: ${fails} FAIL(s) — fix env/${DR_ENV:-<env>}.env before starting"; exit 1; }
