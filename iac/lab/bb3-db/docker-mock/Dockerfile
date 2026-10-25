FROM ubuntu:24.04
COPY bb3-deployment.sh /opt/bb3/bb3-deployment.sh
COPY bb3-prompt.sh /opt/bb3/bb3-prompt.sh
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
	git openssh-client openssh-server coreutils grep util-linux \
	expect \
	&& rm -rf /var/lib/apt/lists/*
RUN useradd --uid 2000 --user-group --create-home --shell /bin/bash mock \
	&& passwd -d mock \
	&& mkdir -p /home/mock/.ssh /home/mock/projects /srv/mock-git /run/sshd /opt/bb3 \
	&& chmod 700 /home/mock/.ssh
COPY mock-authorized_keys /home/mock/.ssh/authorized_keys
COPY mock-client-key /opt/bb3/mock-client-key
COPY mock-ssh-config /opt/bb3/ssh_config
COPY mock-sshd-config /opt/bb3/sshd_config
COPY mock-entrypoint.sh /opt/bb3/mock-entrypoint.sh
COPY mock-repo/ /tmp/mock-repo/
COPY mock-docker /usr/local/bin/docker
RUN chmod 600 /home/mock/.ssh/authorized_keys /opt/bb3/mock-client-key \
	&& chmod 644 /opt/bb3/ssh_config /opt/bb3/sshd_config \
	&& chmod 755 /opt/bb3/mock-entrypoint.sh /usr/local/bin/docker /tmp/mock-repo/scripts/deploy.sh \
	&& ssh-keygen -A \
	&& awk '{print "127.0.0.1 " $1 " " $2}' /etc/ssh/ssh_host_ed25519_key.pub > /opt/bb3/known_hosts \
	&& git init --bare --initial-branch=main /srv/mock-git/bb3-infrastructure.git \
	&& git -C /tmp/mock-repo init -b main \
	&& git -C /tmp/mock-repo config user.name 'BB3 Docker SSH mock' \
	&& git -C /tmp/mock-repo config user.email 'mock@example.invalid' \
	&& git -C /tmp/mock-repo add scripts/deploy.sh \
	&& git -C /tmp/mock-repo commit -m 'Create mock deployment fixture' \
	&& git -C /tmp/mock-repo remote add origin /srv/mock-git/bb3-infrastructure.git \
	&& git -C /tmp/mock-repo push -u origin main \
	&& chown -R mock:mock /srv/mock-git \
	&& chown -R mock:mock /home/mock
ENTRYPOINT ["/bin/bash", "/opt/bb3/mock-entrypoint.sh"]