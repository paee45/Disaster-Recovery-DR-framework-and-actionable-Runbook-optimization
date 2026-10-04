# 12 — Never the Wrong AWS Account or Cluster: Guardrails & Best Practice

During a DR event people are tired, several terminals are open, and DEV/UAT/PROD look the same. A restore or secret
update against the wrong environment is a **second incident**. Defence in depth: four layers, each catches what the previous one missed.

```
 Layer 1  Isolation        separate AWS profiles + separate kubeconfig per env; no defaults
 Layer 2  Pinning          every aws/kubectl call carries --profile/--region/--context (wrappers in dr-lib.sh)
 Layer 3  Verification     dr_guard: account ID, caller role, EKS endpoint ↔ context, cluster identity ConfigMap
 Layer 4  Confirmation     PROD changes need a typed confirmation; irreversible steps have approval gates
```

## Layer 1 — Isolation (set up once per engineer machine / bastion)

| Practice | How |
|---|---|
| **One named AWS profile per env, no `[default]`** | `~/.aws/config`: `[profile dr-dev]`, `[profile dr-uat]`, `[profile dr-prod]` via IAM Identity Center (SSO) or `role_arn` + `mfa_serial`. Delete or empty `[default]` so a forgotten `--profile` fails instead of hitting some account |
| **No long-lived keys in the environment** | Never export `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` in shell profiles. `dr-lib.sh` unsets them and warns |
| **One kubeconfig file per env** | `aws eks update-kubeconfig --name eks-uat --alias dr-uat --kubeconfig ~/.kube/dr-uat.config --profile dr-uat`. The env profile sets `KUBECONFIG=~/.kube/dr-uat.config`, so the PROD cluster is not even in the file while working on UAT |
| **Context names = env names** | Alias contexts `dr-dev`, `dr-uat`, `dr-prod` (not the default ARN), so a mistake is readable |
| **PROD access is separate and short-lived** | PROD role through SSO with a short session and MFA; ideally a separate `DRExecutorRole` assumed only for DR (alerting on assume) |
| **Shell prompt shows env + context** | e.g. starship/kube-ps1 with `AWS_PROFILE` + `kubectl` context; red for prod |

## Layer 2 — Pinning (implemented in `automation/scripts/dr-lib.sh`)

- `aws()` wrapper adds `--profile $AWS_PROFILE --region $AWS_REGION` to **every** call (unless a step passes its own, e.g. a cross-region replica).
- `kubectl()` wrapper adds `--context $EKS_CONTEXT` to **every** call. The scripts never use `kubectl config use-context` and do not depend on the *current* context. The local test proves this: the current context is a decoy pointing at a non-existent cluster, and all tests still hit the right one (test A06).
- `helm` calls use `--kube-context`.
- The wrappers are exported, so child scripts inherit them.
- All values come from **one** env file (`env/<env>.env`). No values are typed into commands (exercise finding F4).

## Layer 3 — Verification (`dr_guard`, runs at the start of every script and in `dr_init`)

| Check | Catches |
|---|---|
| `sts get-caller-identity` account == `ACCOUNT_ID` | Wrong profile, expired SSO falling back to other creds, wrong account |
| Caller ARN matches `AWS_ROLE_PATTERN` (optional) | Working with a personal admin role instead of the DR role |
| Kube context exists in the env's kubeconfig | Typos, missing setup |
| Context API server == `eks describe-cluster --name $EKS_CLUSTER_NAME` endpoint **in that account** | A context that points at a different account's/env's cluster even though the name looks right |
| ConfigMap `kube-system/dr-cluster-identity` has `env=$DR_ENV` and `account=$ACCOUNT_ID` | Any cluster mix-up (works for non-EKS clusters too; the local k3s test uses it) |
| Test seams (`DR_ENDPOINT_MAP`) refused outside `DR_ENV=local` | Local-test settings leaking into a real run |

Create the identity marker once per cluster (part of cluster bootstrap/GitOps):
```bash
kubectl --context dr-uat -n kube-system create configmap dr-cluster-identity \
  --from-literal=env=uat --from-literal=account=111122223333 --from-literal=cluster=eks-uat
```
Guard failures print `GUARD FAIL: …` and the script stops **before** any change. The result is cached per
(env, profile, region, context, account), so child scripts don't re-check unless something changed.

## Layer 4 — Confirmation & approvals

- `dr_confirm` asks you to type `prod` before PROD changes (restore, harden, secret apply/rollback/fix-password, fencing, mass restart). In non-interactive runs it **aborts** unless `DR_ASSUME_YES=1` is set explicitly (test A08).
- Irreversible steps (promotion, cutover) also have the runbook gates (G2/G3) with recorded approvers (SSM `aws:approve`).

## Organisation-level controls (recommended, outside this repo)

| Control | Purpose |
|---|---|
| Separate AWS accounts per env (AWS Organizations) | The account boundary is the strongest isolation; most guard checks rely on it |
| SCP / permission boundaries: deny `rds:DeleteDBInstance`, `rds:PromoteReadReplica`, `secretsmanager:PutSecretValue` on PROD except for `DRExecutorRole` | Even a correct-looking mistake cannot change PROD |
| `DRExecutorRole` assumption → alert (EventBridge on `AssumeRole`) | Every DR session is visible |
| EKS access entries: DR role mapped only to the namespaces it needs | Limits the blast radius in the cluster |
| Deletion protection on all RDS instances, `--no-delete-automated-backups` | A wrong delete does not lose backups |
| CloudTrail + alerts on `RestoreDBInstance*`, `PromoteReadReplica`, `PutSecretValue` | Detects unexpected DR actions |

## How this is tested
- **Locally** (`tests/local/run-tests.sh`, group A): wrong profile, unknown context, decoy context, identity mismatch, decoy as current-context, endpoint-map seam outside local, non-interactive PROD confirmation, profile pinning.
- **Real account** (`tests/aws/sandbox-test.sh readonly`): guard + env check + a negative context test, with zero changes.
