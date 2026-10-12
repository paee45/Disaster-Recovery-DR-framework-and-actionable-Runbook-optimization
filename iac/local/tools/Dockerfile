FROM debian:12.9-slim

ARG TARGETARCH
ARG TERRAFORM_VERSION=1.15.2
ARG AWSCLI_VERSION=2.24.18
ARG KUBECTL_VERSION=1.31.4
ARG HELM_VERSION=3.17.1
ARG DOCKER_VERSION=28.0.1
ARG MOTO_VERSION=5.0.28
ARG PYYAML_VERSION=6.0.2
ARG DEBIAN_SNAPSHOT=20250224T000000Z

RUN set -eu; \
        case "$(uname -m):$TARGETARCH" in \
            x86_64:amd64|aarch64:arm64) ;; \
            *) echo 'tool_arch must match the native Linux engine architecture' >&2; exit 2 ;; \
        esac

RUN printf 'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/%s/ bookworm main\ndeb [check-valid-until=no] http://snapshot.debian.org/archive/debian-security/%s/ bookworm-security main\n' "$DEBIAN_SNAPSHOT" "$DEBIAN_SNAPSHOT" > /etc/apt/sources.list \
    && rm -f /etc/apt/sources.list.d/debian.sources \
    && apt-get -o Acquire::Check-Valid-Until=false update \
    && apt-get install -y --no-install-recommends bash coreutils postgresql-client-15 python3 python3-venv shellcheck ca-certificates curl unzip jq git procps openssl iproute2 iptables \
    && rm -rf /var/lib/apt/lists/*

RUN set -eu; \
    case "$TARGETARCH" in \
      amd64) aws_arch=x86_64; docker_arch=x86_64 ;; \
      arm64) aws_arch=aarch64; docker_arch=aarch64 ;; \
      *) echo 'TARGETARCH must be amd64 or arm64' >&2; exit 2 ;; \
    esac; \
    curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${TARGETARCH}.zip" -o /tmp/terraform.zip; \
    unzip /tmp/terraform.zip terraform -d /usr/local/bin; \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${aws_arch}-${AWSCLI_VERSION}.zip" -o /tmp/aws.zip; \
    unzip -q /tmp/aws.zip -d /tmp; \
    /tmp/aws/install; \
    curl -fsSL "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" -o /usr/local/bin/kubectl; \
    curl -fsSL "https://get.helm.sh/helm-v${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" -o /tmp/helm.tar.gz; \
    tar -xzf /tmp/helm.tar.gz -C /tmp; \
    mv "/tmp/linux-${TARGETARCH}/helm" /usr/local/bin/helm; \
    curl -fsSL "https://download.docker.com/linux/static/stable/${docker_arch}/docker-${DOCKER_VERSION}.tgz" -o /tmp/docker.tgz; \
    tar -xzf /tmp/docker.tgz -C /tmp docker/docker; \
    mv /tmp/docker/docker /usr/local/bin/docker; \
    chmod 755 /usr/local/bin/kubectl; \
    rm -rf /tmp/*

RUN python3 -m venv /opt/drtest-venv \
    && /opt/drtest-venv/bin/pip install --no-cache-dir "moto[server]==${MOTO_VERSION}" "PyYAML==${PYYAML_VERSION}"

ENV PATH="/opt/drtest-venv/bin:${PATH}" \
    AWS_EC2_METADATA_DISABLED=true \
    AWS_CONFIG_FILE=/workspace/tests/local/.state/aws-config \
    AWS_SHARED_CREDENTIALS_FILE=/workspace/tests/local/.state/aws-credentials \
    KUBECONFIG=/workspace/tests/local/.state/kubeconfig
WORKDIR /workspace
CMD ["sleep", "infinity"]