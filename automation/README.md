# Automation

| Path | Used in | Purpose |
|---|---|---|
| `scripts/dr-lib.sh` | All phases | `dr_init`, `dr_mark` (timeline), `dr_run` (evidence capture), `DR_DSN` |
| `scripts/dr-preflight.sh` | P1-S06 | Replica status/lag, SQL LSNs, secret auth, DR EKS + ESO, SSM doc version |
| `ssm/DR-RdsPostgresRegionalFailover.yaml` | P2 | Pre-check → `aws:approve` G2 → promote → wait standalone → CNAME → INSYNC |
| `scripts/dr-verify.sh` | P2-S07, P4 | `wait-promoted`, `db`, `app` probes |
| `scripts/r53-cname-batch.sh` | P2-S08 (manual) | Route 53 UPSERT change batch |
| `scripts/dr-secret-set-host.sh` | P3-S02 (legacy) | Rewrite `host` in secret (replica-secret aware) |
| `scripts/dr-eks-rollout.sh` | P3-S03/S04 | Scale to prod capacity; ordered rollout restart |
| `scripts/dr-collect-evidence.sh` | P4-S07 | CloudTrail/RDS/R53/CW evidence, manifest + sha256, upload to Object Lock bucket |
| `scripts/dr-rto-rpo-calc.py` | P4-S07 | KPIs from `timeline.jsonl` |
| `sql/*.sql` | P1, P2, P4, P5 | Heartbeat, replica pre-flight, planned drain, post-failover verify, reconciliation |
| `k8s/*.yaml` | Steady state | ESO, Deployment DR conventions + Reloader, heartbeat writer, Prometheus alerts |

Deploy the SSM document to **both** regions with IaC:
```bash
aws ssm create-document --region eu-central-1 --name DR-RdsPostgresRegionalFailover \
  --document-type Automation --document-format YAML --content file://automation/ssm/DR-RdsPostgresRegionalFailover.yaml
```
Recommended CI: `shellcheck scripts/*.sh`, `yamllint`, `cfn-lint`-style schema check of the SSM doc, and a monthly L2 drill
(disposable replica → promote → verify → delete) to measure promotion time and catch drift.
