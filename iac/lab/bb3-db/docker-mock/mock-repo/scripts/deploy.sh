#!/usr/bin/env bash
set -euo pipefail
[[ $# == 1 && "$1" == uat ]] || { echo 'mock deploy supports only uat'; exit 2; }
printf 'MOCK REMOTE DEPLOY: scripts/deploy.sh %s completed\n' "$1"