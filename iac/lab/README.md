# DR lab — a UAT-like environment in a sandbox AWS account (Terraform)

A reusable, throw-away copy of the UAT shape to test the runbooks, `dr-run.sh` and `sandbox-test.sh` on **real AWS**
without touching the real UAT. Everything is code: build it, test, destroy it, rebuild it the same way any time.

| Stack | Creates |
|---|---|
| `aws/` | VPC (3 public subnets, IGW) · 3 DB security groups like UAT (app ← VPC, admin ← **your IP /32 only**, monitoring) + quarantine SG · DB subnet group · parameter group · Enhanced Monitoring role · **RDS primary `dr-lab-uat-pg`** built from the sanitised UAT describe (`tests/local/fixtures/rds-primary-uat-like.json`) · EKS `dr-lab-eks` + 1 node · evidence bucket · kubeconfig `~/.kube/dr-uat.config` (context `dr-uat`, no current-context) |
| `k8s/` | Stakater Reloader (repo values) · `kube-system/dr-cluster-identity` (env=uat) · namespace `app` (reloader=enabled) · Secret `db-creds` (`POSTGRES_DB_HOST1/HOST2/PORT/NAME/USER/PASSWORD`) · seed Job (DB `app`, role `app_user`, orders/payments, heartbeat) · `lab-app-1` (Reloader-annotated, HOST1) + `lab-app-2` (not annotated, HOST2) · manual snapshot `dr-lab-seed` · **`env/uat.env`** (git-ignored, no passwords) |

Safety: the AWS provider has `allowed_account_ids = [account_id]` — Terraform refuses to run in any other account.
Every resource is tagged `dr-lab=true`, `managed-by=terraform`.

**Lab-only differences from the real UAT** (on purpose): own public subnets (no NAT, cheaper); the DB is publicly
accessible but reachable **only from your IP** (the DR scripts run `psql` from your laptop); deletion protection off
so `destroy` works; free-tier class `db.t4g.micro` and Performance Insights off by default (variables restore UAT values).

## Cost (approx., while it exists)
| Item | ≈ |
|---|---|
| RDS `db.t4g.micro`, 20 GB gp3 | free tier if the account is eligible, else ~0.02 USD/h |
| EKS control plane | **0.10 USD/h — never free** |
| EKS node `t3.small` + public IPv4 addresses | ~0.04 USD/h |
| **Total** | **~0.15 USD/h (~3.5 USD/day)** → destroy after each session |

## Build
Tools on the Mac: `brew install hashicorp/tap/terraform helm` (plus the DR tools: bash coreutils jq libpq awscli kubectl).
```bash
cd ~/dr-framework/iac/lab/aws
cp terraform.tfvars.example terraform.tfvars          # fill in account_id, aws_profile, operator_cidr
aws sso login --profile pa_sandbox
terraform init && terraform apply                     # ~15 min (EKS is the slow part)
cd ../k8s
terraform init && terraform apply                     # ~5 min: Reloader, Secret, seed, apps, snapshot, env/uat.env
```
Then: `cd ~/dr-framework && source env/uat.env && tests/aws/sandbox-test.sh readonly`.
If your IP changes: `terraform apply -var operator_cidr=<new>/32` in `aws/`.

## Destroy (in this order)
Restores made by the DR scripts are **not** in Terraform state and block the subnet group / SGs — delete them first:
```bash
cd ~/dr-framework && source env/uat.env
for db in $(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-instances \
      --query 'DBInstances[?starts_with(DBInstanceIdentifier,`dr-lab-uat-pg-`)].DBInstanceIdentifier' --output text); do
  aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds modify-db-instance --db-instance-identifier "$db" --no-deletion-protection --apply-immediately >/dev/null
  aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds delete-db-instance --db-instance-identifier "$db" --skip-final-snapshot --delete-automated-backups >/dev/null
  aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds wait db-instance-deleted --db-instance-identifier "$db" && echo "deleted $db"
done
cd iac/lab/k8s && terraform destroy
cd ../aws && terraform destroy
```
State files stay in `iac/lab/*/terraform.tfstate` on your Mac (git-ignored; the k8s state contains the app password
and the seed Job's copy of the master password — keep it private, or move state to an encrypted S3 backend).
