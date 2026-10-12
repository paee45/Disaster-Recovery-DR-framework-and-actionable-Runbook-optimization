# Local mock AWS stack

Run only inside the tools runner with the repository mounted at `/workspace`.
The parent starts patched moto at `127.0.0.1:5000`, LocalStack at
`172.30.0.10:4566`, the Postgres containers, and Kubernetes. This stack owns only
mock AWS resources and the generated profiles, endpoint map, and local env.
It uses AWS provider 6 and the default local backend, never the lab S3 backend.
Do not use `iac/tf.sh` for this stack. Do not reuse/import lab or real AWS state.

From `/workspace`, initialise and validate with:

```sh
terraform -chdir=iac/local/mock init -backend=false
terraform -chdir=iac/local/mock validate
terraform -chdir=iac/local/mock plan -out=mock.plan
```

Review the saved plan before the parent applies it. No AWS CLI or shell provisioner
creates resources. Provider credentials are literal dummy `test` values; do not
export runtime AWS access keys. Every service used by managed resources has a fixed
mock endpoint. The default region is `eu-west-1`. Credential, metadata, account ID,
and region checks are disabled; these switches are not a general network firewall.
Keep execution isolated from real AWS and do not add services without mock endpoints.

The fixture defaults to `tests/local/fixtures/rds-primary-uat-like.json`, resolved
relative to this module rather than the caller's working directory. A different
sanitised fixture can be supplied with `-var=fixture=/workspace/path/to/fixture.json`.
Three subnets use `eu-west-1a/b/c`; three DB SGs and one quarantine SG have no rules.
The primary follows the fixture's configurable fields, with generated network IDs,
IAM monitoring role and KMS key replacing fixture identities. Small gp3 volumes
omit fixed IOPS/throughput, matching `rds-requests.jq`. The replica uses the provider's
same-region read-replica API and inherits source settings where the mock supports it.
Both DB resources have `prevent_destroy`; replacement/destroy deliberately fails.
The primary also retains fixture deletion protection. For a clean local reset,
the parent must deliberately reset mock services and discard only this mock state;
do not silently remove these guards or refresh old state into fresh mocks.

Generated files live under `/workspace/tests/local/.state`: `aws-config` and
`aws-credentials` have mode `0600`, as does `local.env`. The parent must create
`kubeconfig` there with context `dr-local`, cluster identity `local`, and no current
context. Source `local.env` after parent setup. It defaults `SECRET_MODE` to `eso`
for the existing suite while preserving a parent's `SECRET_MODE=k8s` override.
Terraform state contains dummy database/secret passwords; keep it local and ignored.

## Mock limitations

- AWS provider forbids reserved `aws:*` tags. The fixture's CloudFormation tags
  cannot be reproduced here; four user tags exercise tag copying, but the suite's
  reserved-tag filtering needs separate fixture-based coverage.
- `BackupTarget=region` is mapped explicitly (verified against AWS provider 6.67.0).
  Runtime/computed fixture fields such as stopped status, restart time, ARNs,
  resource IDs, and UpgradeRolloutOrder are not mapped by `create_req`.
  Default option groups are engine-selected; custom option groups in alternate
  fixtures must already exist in the mock.
- LocalStack uses account `000000000000`; moto may use `123456789012`. Do not force
  an account ID check across both. Monitoring/PI references point to Terraform's
  LocalStack IAM/KMS resources, not the fixture's ARNs. Mock acceptance does not prove
  real IAM permissions, KMS access, EnhancedMonitoring log delivery, or PI collection.
- Moto's metadata and modify behavior can differ from provider read-back expectations
  (including PI, logs, CA, deletion protection and replica inheritance). Parent-run
  plan/apply/read-back and the existing local tests are required before claiming
  parity or 109/109. Terraform provisioning does not seed real Postgres databases.
- DR operations change mock resources outside Terraform. Review subsequent plans;
  they can reset SGs, secrets or replica state. Do not reconcile while a drill runs.

## Offline validation

On the author's Mac, formatting and `terraform validate` passed using already
installed AWS 6.67.0 and local 2.9.1 plugins, with backend initialisation disabled.
No mock or real AWS APIs, plan, apply, or local suite were run. The generated
Mac-only lock file was removed: initialise in the Linux runner and keep its
multi-platform provider lock when the parent integrates this stack.