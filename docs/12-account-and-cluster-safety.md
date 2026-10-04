# 12 — Never the Wrong AWS Account or Cluster: Guardrails & Best Practice

During a DR event people are tired, several terminals are open, and DEV/UAT/PROD look the same. A restore or secret
update against the wrong environment is a **second incident**. Defence in depth: four layers, each catches what the previous one missed.

```
 Layer 1  Isolation        separate AWS profiles + separate kubeconfig per env; no defaults
 Layer 2  Strict pinning   every aws/kubectl call WRITES --profile/--region/--context; missing → refused (97)
 Layer 3  Verification     dr_guard: account ID, caller role, EKS endpoint ↔ context, cluster identity ConfigMap
 Layer 4  Confirmation     PROD changes need a typed confirmation; irreversible steps have approval gates
```

## Layer 1 — Isolation (set up once per engineer machine / bastion)

| Practice | How |
|---|---|
| **One named AWS profile per env, no `[default]`** | `~/.aws/config`: `[profile dr-dev]`, `[profile dr-uat]`, `[profile dr-prod]` via IAM Identity Center (SSO) or `role_arn` + `mfa_serial`. Delete or empty `[default]` so a forgotten `--profile` fails instead of hitting some account |
| **No long-lived keys in the environment** | Never export `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` in shell profiles. `dr-lib.sh` unsets them and warns |
| **One kubeconfig file per env, no current-context** | `aws --profile dr-uat --region eu-west-1 eks update-kubeconfig --name eks-uat --alias dr-uat --kubeconfig ~/.kube/dr-uat.config`, then `kubectl config unset current-context`. The env profile sets `KUBECONFIG=~/.kube/dr-uat.config`, so the PROD cluster is not even in the file while working on UAT |
| **Context names = env names** | Alias contexts `dr-dev`, `dr-uat`, `dr-prod` (not the default ARN), so a mistake is readable |
| **PROD access is separate and short-lived** | PROD role through SSO with a short session and MFA; ideally a separate `DRExecutorRole` assumed only for DR (alerting on assume) |
| **Shell prompt shows env + context** | e.g. starship/kube-ps1 with `AWS_PROFILE` + `kubectl` context; red for prod |

## Layer 2 — Strict pinning (implemented in `automation/scripts/dr-lib.sh`, on by default)

**Rule: no defaults, ever.** Every `aws` call carries `--profile "$AWS_PROFILE" --region "$AWS_REGION"` and every
`kubectl` call `--context "$EKS_CONTEXT"`, **written on the command itself** — in the scripts, in the runbook snippets and
in the evidence logs. The `aws()`/`kubectl()` wrappers enforce it at run time:

| Call | `DR_STRICT_PIN=1` (default) | `DR_STRICT_PIN=0` (manual convenience) |
|---|---|---|
| flags present and equal to the env file | runs | runs |
| `--profile`/`--region`/`--context` **missing** | **REFUSED, exit 97** (shows the command) | filled in from the env file |
| `--profile`/`--context` naming **another** profile/context | **REFUSED, exit 97** | **REFUSED, exit 97** |
| `kubectl config …` / `kubectl version --client` | runs (local file only) | runs |

- Inside the wrapper `AWS_PROFILE`/`AWS_DEFAULT_PROFILE` are cleared, so the explicit flag is the only thing that selects an account.
- Every call through the wrappers is appended to `evidence/<DR_ID>/commands.jsonl` (timestamp, args with secrets redacted, rc, duration, script, actor) — refusals included.
- The scripts never use `kubectl config use-context`; `helm` uses `--kube-context`.
- All values come from **one** env file (`env/<env>.env`). No values are typed into commands (exercise finding F4).
- **CI/pre-commit lint** (`tests/lint/pinning-lint.sh`, `.github/workflows/dr-lint.yml`, `.githooks/pre-commit` — enable with
  `git config core.hooksPath .githooks`) fails the build if any `aws`/`kubectl` call in `automation/scripts/` or `tests/aws/`
  lacks the flags. A deliberate exception needs a trailing `# pin-lint: ok <reason>`.

Why both a runtime refusal and a lint: the lint catches it before merge, the refusal catches what the lint cannot see
(commands typed in the recorded DR shell, dynamically built commands).

## Layer 3 — Verification (`dr_guard`, runs at the start of every script and in `dr_init`)

| Check | Catches |
|---|---|
| `sts get-caller-identity` account == `ACCOUNT_ID` | Wrong profile, expired SSO falling back to other creds, wrong account |
| Caller ARN matches `AWS_ROLE_PATTERN` (optional) | Working with a personal admin role instead of the DR role |
| Kube context exists in the env's kubeconfig | Typos, missing setup |
| Context API server == `eks describe-cluster --name $EKS_CLUSTER_NAME` endpoint **in that account** | A context that points at a different account's/env's cluster even though the name looks right |
| ConfigMap `kube-system/dr-cluster-identity` has `env=$DR_ENV` and `account=$ACCOUNT_ID` | Any cluster mix-up (works for non-EKS clusters too; the local k3s test uses it) |
| Test seams (`DR_ENDPOINT_MAP`) refused outside `DR_ENV=local` | Local-test settings leaking into a real run |
| **No `[default]` profile** in `$AWS_CONFIG_FILE`/`~/.aws/config` or the credentials file (override: `DR_ALLOW_DEFAULT_PROFILE=1`) | A forgotten flag in a manual command silently using some account |
| **No exported keys** (`AWS_ACCESS_KEY_ID`/`AWS_SESSION_TOKEN`) — sourcing `dr-lib.sh` is refused in strict mode | Static/leftover credentials of another account |
| **No `current-context`** in the env's kubeconfig (override: `DR_ALLOW_CURRENT_CONTEXT=1`); `aws eks update-kubeconfig` sets one → run `kubectl config unset current-context` | A bare `kubectl` hitting whatever cluster was used last |
| **No contexts of other environments** (`dr-dev/uat/prod`) in this env's kubeconfig (override: `DR_ALLOW_FOREIGN_CONTEXTS=1`) | PROD reachable from a UAT session |

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

## How you log in to AWS — SSO or a static key (both supported)

The guard reads what the profile uses (`_dr_auth_type`) and checks it against `DR_AUTH_ALLOWED` in the env file:

| Profile uses | Detected as | Where it lives | Notes |
|---|---|---|---|
| **IAM Identity Center (SSO)** | `sso` | `~/.aws/config`: `sso_session` / `sso_start_url` | Preferred: short-lived, MFA, central off-boarding |
| Assumed role (e.g. on an SSO or key profile) | `role` | `role_arn` + `source_profile` (+ `mfa_serial`) | Good for a dedicated `DRExecutorRole` |
| `credential_process` (aws-vault, 1Password, …) | `process` | `credential_process = …` | Keys never touch disk |
| **Static access key** | `key` | `~/.aws/credentials` under a **named** `[dr-uat]` | Accepted for DEV/UAT; **long-lived** → rotate (≤ 90 days), least privilege, MFA on the user |

Rules that apply to **every** type: the key/profile is selected by `--profile` on each command (never `[default]`, never
exported `AWS_ACCESS_KEY_ID`/`AWS_SESSION_TOKEN` — those are refused). `AWS_ROLE_PATTERN` still decides *who* may run:
for SSO `assumed-role/AWSReservedSSO_lab_admin_`, for a static key `user/<your-iam-user>`.
`env/prod.env.example` sets `DR_AUTH_ALLOWED=sso,role` → a static-key profile is **refused for PROD**; dev/uat allow `key`.
The `GUARD OK` line shows `auth=sso|key|…` (and a rotation reminder for keys).

**SSO and the browser wait.** If the SSO session is missing/expired when a script starts, the guard asks
`SSO login needed for profile 'X' — open the browser now? [Y/n]`, runs `aws sso login --profile X`, **waits in that terminal
until you finish in the browser**, and then carries on with the same command (no re-typing). Options:
- `DR_AUTO_SSO_LOGIN=1` — don't ask, just open the browser.
- `DR_SSO_NO_BROWSER=1` — over SSH/remote: prints the URL + code to open on another machine, still waits here.
- Without a terminal (CI, pipes) nothing can wait for a browser: it stops with `run: aws sso login --profile X`.
- Expiry **during** a long `dr-restore.sh wait` (12+ min) is detected (it does not report "instance missing"): you are
  offered the same login; the restore keeps running on AWS in the meantime. Log in before a DR with `aws sso login`, and ask
  for a session length that covers the exercise (Identity Center → permission set → session duration).
- Role chained on an SSO profile: the login is done for the `source_profile`.
- A static key that is wrong/revoked says so ("not an SSO profile — check the access key / role / MFA") instead of offering a login.

## Your workstation (macOS) — one-time setup
```bash
brew install bash coreutils jq libpq awscli kubectl helm            # dr-lib.sh needs bash>=4 + GNU date (auto-added to PATH)
# ~/.aws/config: named profiles only — NO [default] (also remove [default] from ~/.aws/credentials). SSO shown; a static key goes
# in ~/.aws/credentials as [dr-uat] aws_access_key_id/aws_secret_access_key (DEV/UAT only, see above)
[profile dr-uat]
sso_session = corp
sso_account_id = 111122223333
sso_role_name = lab_admin                                          # set AWS_ROLE_PATTERN='assumed-role/AWSReservedSSO_lab_admin_'
region = eu-west-1
aws sso login --profile dr-uat
aws --profile dr-uat --region eu-west-1 eks update-kubeconfig --name eks-uat --alias dr-uat --kubeconfig ~/.kube/dr-uat.config
KUBECONFIG=~/.kube/dr-uat.config kubectl config unset current-context
```
- Do **not** export `AWS_PROFILE`, `KUBECONFIG` or keys in `~/.zshrc`; the env file sets them for the DR shell only.
- Work in the recorded DR shell: `automation/scripts/dr-session.sh env/uat.env S3` (prompt shows env/profile/context; red for prod).
- Optional, for your *own* terminal outside DR sessions (zsh):
  ```zsh
  aws()     { [[ " $* " == *" --profile "* ]] || { echo "REFUSED: add --profile" >&2; return 97; }; command aws "$@"; }
  kubectl() { [[ " $* " == *" --context "* ]] || { echo "REFUSED: add --context" >&2; return 97; }; command kubectl "$@"; }
  ```

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
- **Locally** (`tests/local/run-tests.sh`, group A): wrong profile, unknown context, decoy context, identity mismatch, endpoint-map seam outside local, non-interactive PROD confirmation; **strict mode**: missing `--profile`/`--region`/`--context` → 97, foreign profile/context → 97 (also with `DR_STRICT_PIN=0`), `[default]` profile, kube `current-context`, foreign env context in the kubeconfig, exported keys → guard/refusal; pinning lint; fill-in mode still ignores a decoy current-context.
- **Real account** (`tests/aws/sandbox-test.sh readonly`): guard + env check + a negative context test, with zero changes.
