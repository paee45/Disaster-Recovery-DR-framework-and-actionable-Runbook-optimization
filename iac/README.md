# IaC — sandbox platform and DR lab (Terraform, state in S3)

Everything that runs in the **sandbox AWS account** is code here. One command runs any stack: [`tf.sh`](tf.sh).
Stacks are small and separate, so each one can be built, paused, destroyed and rebuilt on its own.

| Stack | What it makes | State key in S3 |
|---|---|---|
| `platform/state-bucket` | The S3 bucket that holds every state file (private, versioned, encrypted, TLS only) | `platform/shared/state-bucket` |
| `platform/terrakube` | Terrakube (Terraform UI) on one EC2, no inbound ports | `platform/shared/terrakube` |
| `platform/terrakube-config` | Terrakube organization, deploy/destroy templates, one workspace per lab stack | `platform/shared/terrakube-config` |
| `lab/network` | VPC, 3 public subnets, internet gateway (free) | `lab/shared/network` |
| `lab/eks` | EKS cluster + 1 node, one kubeconfig per env (`~/.kube/dr-<env>.config`) | `lab/shared/eks` |
| `lab/addons` | Reloader (Helm) + `kube-system/dr-cluster-identity` | `lab/shared/addons` |
| `lab/db` | RDS PostgreSQL built from the UAT fixture, its security groups, parameter group, evidence bucket | `lab/<env>/db` |
| `lab/app` | Namespace, DB Secret, seed job, sample apps, seed snapshot, and `env/<env>.env` | `lab/<env>/app` |

`<env>` is `dev`, `uat` or `prod`. All three live in the **one** sandbox account and share **one** EKS cluster; only
`lab/db` and `lab/app` exist once per env. Names carry the env (`dr-lab-uat-pg`, namespace `app` for uat, `app-dev`, …).
Only a UAT fixture exists today (`tests/local/fixtures/rds-primary-uat-like.json`); dev and prod use it until you add
`rds-primary-dev-like.json` / `rds-primary-prod-like.json`.

## State layout (one bucket per account)
```
s3://dr-tfstate-<account>-<region>/
├── platform/shared/{state-bucket,terrakube,terrakube-config}/terraform.tfstate
└── lab/
    ├── shared/{network,eks,addons}/terraform.tfstate
    ├── dev/{db,app}/terraform.tfstate
    ├── uat/{db,app}/terraform.tfstate
    └── prod/{db,app}/terraform.tfstate
```
Key = `<project>/<env or shared>/<component>/terraform.tfstate`. The same layout will be used in the real UAT and PROD
accounts, each with its own bucket. The state of the state-bucket stack lives in the bucket it created.

**S3 is the source of truth.** On every run `tf.sh` checks the bucket first:
- state already in S3 → it is used, from any machine; a leftover local `terraform.tfstate` is set aside as `*.bak`;
- no state in S3 yet and a local `terraform.tfstate` exists → it is copied into S3 (initial setup / bootstrap);
- neither → a fresh stack.
If S3 cannot be checked (login, permissions, network) it stops instead of guessing.

## One-time setup on the Mac
Do this once per machine. Every step is safe to repeat.
```bash
# 1. Tools (the DR scripts need bash 5, coreutils, jq, libpq, awscli, kubectl as well; see tests/README.md)
brew install hashicorp/tap/terraform awscli kubectl jq libpq
brew install mkcert && brew install --cask session-manager-plugin      # only for the Terrakube UI

# 2. AWS login: create the profile lab_sandbox once (see "AWS login" below), then log in
aws sso login --profile lab_sandbox            # SSO profiles only; an access-key profile needs no login

# 3. Settings file (git-ignored; holds the account id): fill in the 4 values
cd ~/dr-framework/iac
cp sandbox.env.example sandbox.env
```
In `sandbox.env`: `TF_VAR_account_id` (12 digits), `TF_VAR_aws_profile=lab_sandbox`, `TF_VAR_region`, and
`TF_VAR_state_bucket=dr-tfstate-<account>-<region>`. For the Terrakube UI also do the one-time certificate and
`/etc/hosts` steps in [platform/terrakube/README.md](platform/terrakube/README.md#one-time-on-the-mac).

### AWS login (SSO or access key)
`tf.sh`, the DR scripts and Terraform all use one **named profile** from `~/.aws/config`. Both login kinds work. The real
environments may use access keys, so pick the profile type that matches the account.

| Profile type | Create it | Log in | Use for |
|---|---|---|---|
| **SSO** (preferred) | `aws configure sso` (answer: SSO start URL, region, pick the account and role; session name e.g. `lab_admin`, profile name `lab_sandbox`) | `aws sso login --profile lab_sandbox` (browser; `tf.sh` does it for you when expired) | sandbox, PROD |
| **Access key** (IAM user) | `aws configure --profile real_uat` (asks access key id, secret, region) | none (the key does not expire; rotate it) | dev / UAT of a real account |
| **Assumed role** | `~/.aws/config`: `role_arn = …`, `source_profile = <an SSO or key profile>` (+ `mfa_serial` if required) | follows the source profile | PROD when keys are not allowed |

Rules (the same ones the DR scripts enforce):
- Never `export AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN`: exported keys can point at any account, so
  `tf.sh` and the DR scripts refuse to run. Keep keys in the named profile only (`~/.aws/credentials`).
- Do not rely on the `[default]` profile; always name the profile.
- Which kinds are allowed is set per environment: `DR_AUTH_ALLOWED` in `env/<env>.env` (dev/uat `sso,role,key`; prod `sso,role`)
  and, for `tf.sh`, `TF_AUTH_ALLOWED` in `sandbox.env` (default: all kinds; set `sso,role` for a real PROD account).
- The account id in `sandbox.env` must match the profile's account; the AWS provider stops Terraform otherwise.
- An IAM user (access key) needs permissions too: read access to what the stacks manage, and `s3:ListBucket` plus
  `s3:GetObject/PutObject/DeleteObject` on the state bucket (S3 locking writes a small `.tflock` object, even for a plan).

Quick check that the machine is ready (all lines should print a path, `1` or `OK`):
```bash
for t in terraform aws kubectl jq mkcert session-manager-plugin; do command -v $t || echo "MISSING $t"; done
grep -c terrakube.platform.local /etc/hosts; ls ~/.terrakube-tls
aws --profile lab_sandbox --region ap-southeast-1 sts get-caller-identity --query Arn --output text
```
`sandbox.env` holds the account id, so it is never committed. The bucket name is `dr-tfstate-<account>-<region>`.

## Using `tf.sh`
```bash
./tf.sh <stack> [env] <terraform command…>
./tf.sh lab/network plan -out=n.plan        # 1. look at the plan
./tf.sh lab/network apply n.plan            # 2. apply exactly that plan
./tf.sh lab/db uat plan -out=d.plan         # per-env stacks take the env as the 2nd word
```
It logs in to SSO when needed, picks the S3 key, runs `terraform init`, and passes the account, profile and region as
variables. `lab/db` also gets your current public IP as `operator_cidr` (the only address allowed to reach Postgres).
Always **plan to a file, read it, then apply that file**.

## Build order (a test session)
| # | Command | About |
|---|---|---|
| 1 | `./tf.sh platform/state-bucket plan -out=b.plan` then `apply b.plan` | Once per account. Free. |
| 2 | `./tf.sh lab/network …` | Free. Keep it between sessions. |
| 3 | `./tf.sh lab/eks …` | ~15 min. EKS control plane costs ~0.10 USD/h. |
| 4 | `./tf.sh lab/addons …` | Reloader + cluster identity. |
| 5 | `./tf.sh lab/db uat …` | RDS, from the UAT fixture. |
| 6 | `./tf.sh lab/app uat …` | Secret, seed, sample apps, snapshot, **writes `env/uat.env`**. |
| 7 | `source env/uat.env && tests/aws/sandbox-test.sh readonly` | Then `full`. See [tests/README.md](../tests/README.md). |

## Saving money
| Resource | Pause | Cost while paused |
|---|---|---|
| RDS | `./tf.sh lab/db uat stop` (start: `… start`; RDS restarts itself after 7 days) | Storage only |
| EKS nodes | `./tf.sh lab/eks apply -var node_desired_size=0` (resume with `1`) | Control plane ~0.10 USD/h |
| Whole cluster | Destroy `lab/app`, `lab/addons`, `lab/eks` (in that order) | 0 |
| Terrakube EC2 | `./tf.sh platform/terrakube apply -var running=false` (`true` to start) | ~2.4 USD/month disk |

**Destroy order:** `lab/app` → `lab/db` (first delete restores made by the DR scripts; they are not in Terraform and
block the subnet group, see [lab/README.md](lab/README.md)) → `lab/addons` → `lab/eks` → `lab/network`. Never destroy
`platform/state-bucket` while any stack still keeps state in it (it has `prevent_destroy`).

## Rules
- **One runner per stack at a time:** either `tf.sh` or Terrakube. The S3 lock stops a double run, but check Terrakube's
  state behaviour first (see below).
- No account ids, ARNs or hostnames in git. `sandbox.env`, `*.tfvars`, `*.plan` and `env/*.env` are git-ignored.
- The AWS provider has `allowed_account_ids`: Terraform refuses to run in any other account.

## Resources exist but there is no state
`./tf.sh status` shows `ORPHAN` for a stack when AWS holds its resources but S3 has no state for it. `tf.sh` then
warns on `plan` and **stops** `apply` / `destroy`, because Terraform would try to create what already exists.
Typical errors you would otherwise see: `DBInstanceAlreadyExists`, `EntityAlreadyExists` (IAM role),
`ResourceInUseException` (EKS cluster), `... already exists` (security group, subnet group, bucket).

Choose one:
1. **Restore the state.** It was lost or is under another key: bring back an earlier object version in the state
   bucket (S3 versioning is on), or run with the right key, then run again.
2. **Import the resources** (to keep them): `./tf.sh <stack> [env] import <address> <id>` (or `import {}` blocks in
   the code), then `plan` until it says "No changes". Set `TF_ADOPT=1` for these runs so the guard does not stop you.
3. **Delete and rebuild** (throw-away lab only): delete them as in [lab/README.md](lab/README.md) (Destroy), then build normally.

## Terrakube (the UI)
[`platform/terrakube/README.md`](platform/terrakube/README.md) builds the UI host; `platform/terrakube-config` creates the
organization, templates and workspaces **as code** (deploy = plan, approve, apply; destroy = plan destroy, approve,
apply). Not proven yet: Terrakube's docs do not say whether a run keeps the `backend "s3"` of the code. Test with
`lab-network` first (state object appears at `lab/shared/network/terraform.tfstate` and `tf.sh lab/network plan` says
"No changes"). If it does not, point Terrakube's own storage at S3 instead and let Terrakube be the only runner of the lab.
