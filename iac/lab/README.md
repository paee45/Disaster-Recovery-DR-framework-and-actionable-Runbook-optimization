# DR lab — UAT-like environments in the sandbox AWS account (Terraform)

A reusable, throw-away copy of the UAT shape (and dev / prod shapes) to test the runbooks, `dr-run.sh` and
`sandbox-test.sh` on **real AWS** without touching the real environments. Build it, test, pause or destroy it, rebuild it
the same way. How to run the stacks, the state layout and the cost routine are in [../README.md](../README.md).

| Stack | Shared or per env | Creates |
|---|---|---|
| `network/` | shared | VPC, 3 public subnets, internet gateway |
| `eks/` | shared | EKS `dr-lab-eks` + 1 node (`t3.small`), kubeconfig `~/.kube/dr-<env>.config` per env (context `dr-<env>`, no current-context) |
| `addons/` | shared | Stakater Reloader (repo values) · `kube-system/dr-cluster-identity` |
| `db/` | per env | 3 DB security groups like UAT (app ← VPC, admin ← **your IP /32 only**, monitoring) + quarantine SG · DB subnet group · parameter group · Enhanced Monitoring role · **RDS primary `dr-lab-<env>-pg`** built from the sanitised UAT describe · evidence bucket |
| `app/` | per env | Namespace (`app` for uat, `app-<env>` otherwise, `reloader=enabled`) · Secret `db-creds` (`POSTGRES_DB_HOST1/HOST2/PORT/NAME/USER/PASSWORD`) · seed Job (DB `app`, role `app_user`, orders/payments, heartbeat) · `lab-app-1` (Reloader-annotated, HOST1) + `lab-app-2` (not annotated, HOST2) · manual snapshot `dr-lab-<env>-seed` · **`env/<env>.env`** (git-ignored, no passwords) |

Why split: the DB can be stopped, rebuilt or destroyed without touching the cluster, and the cluster is paid for only
while you test. The Kubernetes provider is never configured before the cluster exists (`addons` and `app` read the
cluster from the `eks` state).

Safety: the AWS provider has `allowed_account_ids = [account_id]` — Terraform refuses to run in any other account.
Every resource is tagged `dr-lab=true`, `managed-by=terraform`.

**Lab-only differences from the real UAT** (on purpose): own public subnets (no NAT, cheaper); the DB is publicly
accessible but reachable **only from your IP** (the DR scripts run `psql` from your laptop); deletion protection off so
`destroy` works; free-tier class `db.t4g.micro` and Performance Insights off by default (`-var db_instance_class=` and
`-var performance_insights=true` restore the UAT values); one cluster for all envs.

**One cluster, three envs:** `kube-system/dr-cluster-identity` can say only one env (`identity_env`, default `uat`).
`env/dev.env` and `env/prod.env` made by this lab therefore get `REQUIRE_CLUSTER_IDENTITY=false`; uat gets `true`.

## Cost (approx., while it exists)
| Item | ≈ |
|---|---|
| RDS `db.t4g.micro`, 20 GB gp3 (per env) | free tier if the account is eligible, else ~0.02 USD/h; storage only when stopped |
| EKS control plane | **0.10 USD/h — never free** |
| EKS node `t3.small` + public IPv4 addresses | ~0.04 USD/h |
| **Total (one env)** | **~0.15 USD/h (~3.5 USD/day)** → destroy or pause after each session |

## Build
Follow the build order in [../README.md](../README.md#build-order-a-test-session). After `lab/app` finishes:
```bash
cd ~/dr-framework && source env/uat.env && tests/aws/sandbox-test.sh readonly
```
If your IP changes, run `./tf.sh lab/db uat apply` again (it takes the new IP automatically).

## Destroy (in this order)
**All at once:** `iac/lab/destroy-all.sh` removes what is deployed in the order below. It skips stacks with nothing in their
state, saves a destroy plan per stack, shows what goes and asks before applying that file (type `prod` for prod). It keeps
a shared stack while something that needs it is still deployed, and never touches `platform/*`.
```bash
iac/lab/destroy-all.sh --plan-only                 # look only: destroy plan of every deployed stack, nothing applied
iac/lab/destroy-all.sh                             # dev + uat, then cluster and network if nothing else uses them
iac/lab/destroy-all.sh --env uat --keep-shared     # only lab/app + lab/db of uat
iac/lab/destroy-all.sh --env prod                  # prod only when named
```
It is idempotent: if one stack fails, fix it and run it again. The DB has `skip_final_snapshot = true`: **its data is gone**.
To save money without losing data, pause instead (`./tf.sh lab/db uat stop`, `./tf.sh lab/eks apply -var node_desired_size=0`).

**By hand**, one stack at a time (same order; in the Terrakube UI use the `destroy` template of each workspace):

Restores made by the DR scripts are **not** in Terraform state and block the subnet group / SGs — delete them first
(the script offers this):
```bash
cd ~/dr-framework && source env/uat.env
for db in $(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds describe-db-instances \
      --query "DBInstances[?starts_with(DBInstanceIdentifier,\`${PRIMARY_DB}-\`)].DBInstanceIdentifier" --output text); do
  aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds modify-db-instance --db-instance-identifier "$db" --no-deletion-protection --apply-immediately >/dev/null
  aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds delete-db-instance --db-instance-identifier "$db" --skip-final-snapshot --delete-automated-backups >/dev/null
  aws --profile "$AWS_PROFILE" --region "$AWS_REGION" rds wait db-instance-deleted --db-instance-identifier "$db" && echo "deleted $db"
done
cd iac
./tf.sh lab/app uat destroy && ./tf.sh lab/db uat destroy       # per env
./tf.sh lab/addons destroy && ./tf.sh lab/eks destroy && ./tf.sh lab/network destroy
```
State lives in S3 (see [../README.md](../README.md)); the `app` state contains the app password and the seed Job's copy of
the master password, which is why the bucket is private and encrypted.
