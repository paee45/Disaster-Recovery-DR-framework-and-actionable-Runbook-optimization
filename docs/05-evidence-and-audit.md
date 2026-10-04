# 05 — Evidence Collection & Compliance Audit Trail

## 1. Principles
- **Collect while executing.** Every automated step writes its output into the run directory, so nothing is collected from memory afterwards.
- **Immutable.** Store evidence in a dedicated **log-archive account**, in an S3 bucket with **Object Lock (compliance mode)**, SSE-KMS, versioning, and cross-region replication. Executors can write but cannot delete.
- **Verifiable.** A `manifest.json` lists each file with its SHA-256 hash. The manifest itself is hashed and the hash is posted in the incident timeline.
- **Same process for drills and real events.** Auditors want proof that drills follow the production procedure.

## 2. Evidence bundle structure

```
s3://org-dr-evidence-<acct>/
  <env>/<yyyy>/<incident-or-drill-id>/
    manifest.json                 # file list + sha256 + collector identity + git SHA of runbook
    timeline.jsonl                # dr_mark events (T0..T10), UTC
    rto-rpo-report.json|md        # computed by dr-rto-rpo-calc.py
    approvals/                    # SSM aws:approve outputs / incident-tool decision log (G1..G5)
    db/
      preflight-replica.txt       # LSNs, last replay ts, lag (BEFORE promotion)
      describe-db-instances-before.json / -after.json
      rds-events.json
      postfailover-checks.txt     # pg_is_in_recovery, write probe, row counts, heartbeat
    aws/
      cloudtrail-<event>.json     # PromoteReadReplica, ChangeResourceRecordSets, PutSecretValue, UpdateRoutingControlState
      ssm-execution.json          # aws ssm get-automation-execution
      route53-record-before|after.json + dig outputs from both VPCs
      cloudwatch-replicalag.json
    k8s/
      rollout-status-<deploy>.txt
      pods-wide.txt, events.txt, externalsecret-status.yaml
    app/
      synthetic-results.json, smoke-tests.txt
    comms/
      sent-messages.md            # copies of each notification + timestamp + audience
    pir/                          # post-incident review / drill report (added later, new object version)
```

Collector: [`automation/scripts/dr-collect-evidence.sh`](../automation/scripts/dr-collect-evidence.sh). Manifest schema:
[`templates/evidence/evidence-manifest.example.json`](../templates/evidence/evidence-manifest.example.json).

## 3. Bucket configuration (essentials)

```bash
aws s3api create-bucket --bucket org-dr-evidence-111122223333 --region eu-west-1 \
  --create-bucket-configuration LocationConstraint=eu-west-1 --object-lock-enabled-for-bucket

aws s3api put-object-lock-configuration --bucket org-dr-evidence-111122223333 \
  --object-lock-configuration '{"ObjectLockEnabled":"Enabled",
     "Rule":{"DefaultRetention":{"Mode":"COMPLIANCE","Years":7}}}'
# + bucket policy: deny s3:Delete*, deny non-TLS, allow PutObject only from DRExecutorRole in workload accounts
# + replication to a Region B bucket (also Object Lock), so evidence can be written while Region A is down
```

> Use **GOVERNANCE** mode in DEV/UAT (it can be overridden with a special permission). Use **COMPLIANCE** mode for PROD
> (nobody, including root, can delete before retention ends). Confirm the retention period with GRC/Legal.

## 4. Control mapping (example — confirm with your GRC team)

| Framework | Control (abbrev.) | Evidence from this framework |
|---|---|---|
| ISO/IEC 27001:2022 | A.5.29 Information security during disruption; A.5.30 ICT readiness for business continuity; A.8.13 Information backup; A.8.14 Redundancy | Drill reports, measured RTO/RPO, runbook versions, backup restore tests |
| ISO 22301 | 8.4 BC plans and procedures; 8.5 Exercise programme | Runbooks, drill schedule, PIRs |
| SOC 2 (TSC 2017) | A1.2 (recovery infrastructure), A1.3 (recovery plan testing), CC7.4/CC7.5 (incident response and recovery) | Evidence bundles, approvals, comms log |
| DORA (EU financial entities / ICT providers to them) | ICT business continuity, backup & restoration, testing | Same, plus test reports and lessons learned |

## 5. Closure checklist (Gate: incident cannot close without it)
- [ ] `manifest.json` uploaded, and its hash posted in the incident timeline
- [ ] RTO/RPO report generated and stated in the PIR
- [ ] All gate approvals present (G1–G4; G5 for failback)
- [ ] Comms log complete (every sent template with timestamp and audience)
- [ ] Deviations from the runbook listed, each with a backlog ticket
- [ ] For data loss: reconciliation report and business sign-off
