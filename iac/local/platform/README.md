# Local platform

This root owns only the Docker network, three PostgreSQL databases, LocalStack,
patched moto, k3s, and the tools runner. Mock resource creation, Kubernetes
configuration, and orchestration belong to separate modules/wrappers. Do not run
the old shell-based up/down scripts against these Terraform-owned containers.

Required inputs: `repository_path` is the absolute HOST checkout root, using
forward slashes even on Windows; `tool_arch` is the Linux ENGINE architecture
(`arm64` or `amd64`). `docker_host` defaults to `unix:///var/run/docker.sock`.
Select the workstation's engine endpoint explicitly when it differs. The build
must run natively on that engine architecture; TARGETARCH is passed explicitly.

The Linux engine must support privileged containers, host networking, and Docker
28+ bridge `nat-unprotected`. macOS/Windows require a Linux VM engine with host
networking enabled; Windows containers are unsupported. Endpoints refer to the
engine network namespace, not the workstation. Docker Desktop host networking
does not guarantee pod-to-bridge routing: that path still needs runtime testing.

The runner mounts only automation (read-only), tests/local (read-write), tests/lint (read-only), local evidence, iac/local
(read-write), runbooks (read-only), and templates (read-only). No entire checkout,
real env files, sandbox config, home AWS credentials, or home kubeconfig is mounted.
Keep real credentials out of the mounted test tree. Local credentials and the
isolated kubeconfig are produced later under tests/local/.state.

`expose_docker_socket` defaults to false. Opting in is for setup only and grants
the runner control of the ENTIRE Docker engine, including access through arbitrary
host mounts. This is not a sandbox boundary. Set it back to false after setup.
`docker_socket_path` is the engine-host socket bind source, independent of the
workstation's `docker_host` provider endpoint. k3s is also privileged.

PostgreSQL first-boot initialization uploads the original tests/local/seed.sql
and a rendered psql invocation into each container, without local-exec. Old and
replica contain 100 orders / 50 payments with apppw-current; restored contains
80 / 40 with apppw-OLD and heartbeat age 1020 minutes. Master password is masterpw.
These are local fixture passwords only. Named volumes preserve subsequent DR
changes. Replacing a container does NOT reseed an existing volume. For a clean
reset, destroy this root (including its managed volumes), then plan and apply it
again through the owning wrapper. This deletes all local database and k3s data.
Destroy does not delete tests/local/.state or evidence: wrappers own that cleanup.

Outputs: network name/subnet; postgres container/host/port/database/volume map;
engine-local endpoints; runner image/container/workdir/socket flag/isolated file
paths; k3s container/volume/source kubeconfig path. Outputs do not promise that
mock resources or Kubernetes workloads have been configured.

Validation without engine access:

```sh
terraform -chdir=iac/local/platform init -backend=false
terraform -chdir=iac/local/platform validate
terraform -chdir=iac/local/platform fmt -check
```

No apply, image build, Docker startup, or AWS access is needed for these checks.