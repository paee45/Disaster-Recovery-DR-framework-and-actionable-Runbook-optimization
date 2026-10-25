#!/usr/bin/env bash
set -euo pipefail
set +x
runuser -u mock -- git clone /srv/mock-git/bb3-infrastructure.git /home/mock/projects/bb3-infrastructure
/usr/sbin/sshd -t -f /opt/bb3/sshd_config
/usr/sbin/sshd -D -e -f /opt/bb3/sshd_config > /tmp/sshd.log 2>&1 &
if [[ "${BB3_DEPLOYMENT_MODE:-automatic}" == guided \
  && "${BB3_DOCKER_GUIDED_ACTIONS+x}" == x ]]; then
  set +e
  expect <<'EXPECT'
set timeout 60
spawn /usr/bin/env BB3_DEPLOYMENT_SSH_CONFIG=/opt/bb3/ssh_config \
  /bin/bash /opt/bb3/bb3-deployment.sh --mock-ssh guided
foreach action [split $env(BB3_DOCKER_GUIDED_ACTIONS) ","] key {PULL DEPLOY VERIFY SERVICES TASKS} {
  expect -re [format {\[%s\].*skip: } $key]
  switch -- $action {
    run {puts [format "\n\[MOCK INPUT\] Enter %s" $key]; send "\r"}
    skip {puts [format "\n\[MOCK INPUT\] s %s" $key]; send "s\r"}
    stop {puts [format "\n\[MOCK INPUT\] n %s" $key]; send "n\r"}
    default {puts stderr "invalid mock action: $action"; exit 97}
  }
  if {$action eq "stop"} {break}
}
expect -re {Stopped before TASKS.*}
expect eof
set result [wait]
exit [lindex $result 3]
EXPECT
  RESULT=$?
  set -e
else
  /usr/bin/env BB3_DEPLOYMENT_SSH_CONFIG=/opt/bb3/ssh_config \
    /bin/bash /opt/bb3/bb3-deployment.sh --mock-ssh automatic || RESULT=$?
fi
cat /tmp/sshd.log >&2
exit "${RESULT:-0}"