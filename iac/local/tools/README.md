# Tools image

The parent platform passes its Docker provider to this image module. Inputs:
`tool_arch` (required Linux engine native architecture) and `tools_image` (tag).
Outputs: `image_id` and `image_name`. Image building happens on apply, not init.

Terraform 1.15.2 matches the installed workstation version verified during this
implementation. AWS CLI 2.24.18 supports service-specific endpoint configuration.
kubectl 1.31.4 matches k3s; Helm 3.17.1, Docker CLI 28.0.1, moto 5.0.28, and
PyYAML 6.0.2 are pinned. Debian 12.9 and the dated Debian package snapshot pin the
distribution tools (bash, coreutils, PostgreSQL client, Python, shellcheck).
Python transitive dependencies are not locked. Revisit these pins for security
updates; builds need internet access and have not been exercised by validation.

The image contains no copied repository, credentials, kubeconfig, or Docker
daemon. `/workspace` is its workdir; its default command keeps the runner alive.
The separate moto container invokes the existing patched launcher using the same
image's virtual environment. Runtime smoke tests and cross-platform networking
are required before calling the lab portable in production use.