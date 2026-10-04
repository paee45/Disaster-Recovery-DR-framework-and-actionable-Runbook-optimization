# 05 — Evidence Collection & Compliance Audit Trail

## 1. Principles
- **Collect while executing.** Every automated step writes its output into the run directory, so nothing is collected from memory afterwards.
- **Immutable.** Store evidence in a dedicated **log-archive account**, in an S3 bucket with **Object Lock (compliance mode)**, SSE-KMS, versioning, and cross-region replication. Executors can write but cannot delete.
- **Verifiable.** A `manifest.json` lists each file with its SHA-256 hash. The manifest itself is hashed and the hash is posted in the incident timeline.
- **One process for every recovery.** The same bundle structure is used for real events and for any future test.

## 2. Evidence bundle structure

```
s3://org-dr-evidence-<acct>/
  <env>/<yyyy>/<incident-or-drill-id>/
    manifest.json                 # file list + sha256 + collector identity + git SHA of runbook
    timeline.jsonl                # dr_mark events (T0..T10), UTC
    rto-rpo-report.json|md        # computed by dr-rto-rpo-calc.py
    approvals/                    # SSM aws:approve outputs / incident-tool decision log (G1..G4, FB-G0)
    db/
      replica-final.txt           # S2: LSNs, last replay ts, heartbeat (BEFORE promotion)
      describe-<db>.json          # target, old primary, replica (after) + src-config (before, S3/S4)
      rds-events-<db>.json        # S1 failover reason/time; promote/restore progress
      db-post.txt                 # 20-postfailover-verify output; restore-point check (S3/S4)
      fence-<db>.*                # saved SGs / read-only state (CP-04)
    aws/
      cloudtrail-<event>.json     # PromoteReadReplica, RestoreDBInstance*, RebootDBInstance, ModifyDBInstance,
                                  # PutSecretValue, UpdateSecretVersionStage, CancelRotateSecret, StartAutomationExecution
      secret-<id>.before|after.json  # host/port/dbInstanceIdentifier + version IDs only — NEVER the password
      secret-meta-<id>.json       # VersionIdsToStages, rotation state
      ssm-execution.json          # aws ssm get-automation-execution
      cloudwatch-replicalag.json
    k8s/
      inventory-<secret>.txt      # consumers + Reloader annotation status
      generations-<secret>.tsv, rollout-status-<kind_name>.txt   # proof Reloader rolled each consumer
      pods-wide.txt, events.txt, cronjobs-<secret>.txt
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
# + replication to a bucket in a second region (also Object Lock): evidence survives a regional event
```

> Use **GOVERNANCE** mode in DEV/UAT (it can be overridden with a special permission) and **COMPLIANCE** mode for PROD
> (nobody, including root, can delete before retention ends). The retention period follows the ISMS records-retention policy (`TODO`), approved by the CTO.

## 4. Control mapping

The ISO/IEC 27001:2022 scope, Annex A mapping and DR risk register are in [09 — ISO 27001 scope](09-iso27001-scope.md).
Evidence from this bundle supports A.5.24–A.5.30, A.5.33, A.5.37, A.8.13–A.8.16 and A.8.32.

## 5. Closure checklist (Gate: incident cannot close without it)
- [ ] `manifest.json` uploaded, and its hash posted in the incident timeline
- [ ] RTO/RPO report generated and stated in the PIR
- [ ] All gate approvals present (G1–G4; G5 for failback)
- [ ] Comms log complete (every sent template with timestamp and audience)
- [ ] Deviations from the runbook listed, each with a backlog ticket
- [ ] For data loss: reconciliation report and business sign-off
