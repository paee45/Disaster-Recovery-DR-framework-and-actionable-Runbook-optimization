FROM ubuntu:24.04
COPY bb3-deployment.sh /opt/bb3/bb3-deployment.sh
COPY bb3-prompt.sh /opt/bb3/bb3-prompt.sh
USER 65534:65534
ENTRYPOINT ["/bin/bash", "/opt/bb3/bb3-deployment.sh"]