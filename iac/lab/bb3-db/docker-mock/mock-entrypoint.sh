#!/usr/bin/env bash
set -euo pipefail
set +x
runuser -u mock -- git clone /srv/mock-git/bb3-infrastructure.git /home/mock/projects/bb3-infrastructure
/usr/sbin/sshd -t -f /opt/bb3/sshd_config
/usr/sbin/sshd -D -e -f /opt/bb3/sshd_config > /tmp/sshd.log 2>&1 &
/usr/bin/env BB3_DEPLOYMENT_SSH_CONFIG=/opt/bb3/ssh_config \
  /bin/bash /opt/bb3/bb3-deployment.sh --mock-ssh "${BB3_DEPLOYMENT_MODE:-automatic}" || RESULT=$?
cat /tmp/sshd.log >&2
exit "${RESULT:-0}"