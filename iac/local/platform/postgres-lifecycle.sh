#!/usr/bin/env bash
set -euo pipefail
: "${DOCKER_HOST:?}" "${CONTAINER_ID:?}" "${CONTAINER_NAME:?}" "${WANT_RUNNING:?}"
[[ "$DOCKER_HOST" == unix://* && "$CONTAINER_NAME" =~ ^drtest-pg-(old|replica|restored)$ \
  && "$WANT_RUNNING" =~ ^(true|false)$ ]] || { echo 'REFUSED: unexpected local lifecycle target.' >&2; exit 2; }
actual_name="$(docker --host "$DOCKER_HOST" inspect "$CONTAINER_ID" --format '{{.Name}}')"
[[ "$actual_name" == "/$CONTAINER_NAME" ]] || { echo 'REFUSED: container ID/name mismatch.' >&2; exit 2; }
action=stop; [[ "$WANT_RUNNING" != true ]] || action=start
docker --host "$DOCKER_HOST" container "$action" "$CONTAINER_ID"
actual="$(docker --host "$DOCKER_HOST" inspect "$CONTAINER_ID" --format '{{.State.Running}}')"
[[ "$actual" == "$WANT_RUNNING" ]] || { echo 'Container lifecycle verification failed.' >&2; exit 1; }
echo "Verified $CONTAINER_NAME running=$actual (existing container, volume retained)."