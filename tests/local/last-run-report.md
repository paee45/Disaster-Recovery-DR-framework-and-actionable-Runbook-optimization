| # | Test | Result | Log |
|---|---|---|---|
| A01 | guard passes with the pinned profile + context | PASS | logs/A01.log |
| A02 | wrong AWS profile (other account) is refused | PASS | logs/A02.log |
| A03 | unknown kube context is refused | PASS | logs/A03.log |
| A04 | decoy context (other cluster) is refused | PASS | logs/A04.log |
| A05 | cluster whose identity says env=uat is refused | PASS | logs/A05.log |
| A06 | fill-in mode (DR_STRICT_PIN=0) ignores current-context (decoy), uses EKS_CONTEXT | PASS | logs/A06.log |
| A07 | local endpoint-map seam refused outside DR_ENV=local | PASS | logs/A07.log |
| A08 | PROD confirmation blocks non-interactive changes (no DR_ASSUME_YES) | PASS | logs/A08.log |
| A09 | pinned aws call: caller account = 000000000000 | PASS | logs/A09.log |
| A10 | strict: aws without --profile/--region → REFUSED (97) | PASS | logs/A10.log |
| A11 | strict: aws --profile dr-decoy → REFUSED (97), even with DR_STRICT_PIN=0 | PASS | logs/A11.log |
| A12 | strict: kubectl without --context → REFUSED (97) | PASS | logs/A12.log |
| A13 | strict: kubectl --context decoy → REFUSED (97) | PASS | logs/A13.log |
| A14 | a [default] AWS profile makes the guard fail | PASS | logs/A14.log |
| A15 | a kube current-context makes the guard fail | PASS | logs/A15.log |
| A16 | kubeconfig holding another env's context (dr-prod) makes the guard fail | PASS | logs/A16.log |
| A17 | exported static AWS keys are refused (strict) | PASS | logs/A17.log |
| A18 | pinning lint: every aws/kubectl call in the scripts is pinned | PASS | logs/A18.log |
| B01 | dr-env-check.sh S3 → PASS | PASS | logs/B01.log |
| B02 | inventory: app-a/app-b Reloader YES, app-c NO, CronJob listed | PASS | logs/B02.log |
| B03 | preflight restore → PASS (inputs copied from source) | PASS | logs/B03.log |
| B04 | preflight replica → PASS | PASS | logs/B04.log |
| C00 | capture baseline of the source (describe + 4 tags + pg_settings) | PASS | logs/C00.log |
| C01 | list-snapshots | PASS | logs/C01.log |
| C01b | plan: request from baseline (3 SGs, subnets, PG, retention 7, logs, tags) — no change made | PASS | logs/C01b.log |
| C02 | restore snapshot with the baseline request (--cli-input-json) | PASS | logs/C02.log |
| C03 | wait until available (progress + T5) | PASS | logs/C03.log |
| C03b | validate right after restore: SGs, subnets, PG, retention 7, logs, tags already match | PASS | logs/C03b.log |
| C03c | CLI default retention 1 day + lost tag → validate detects both | PASS | logs/C03c.log |
| C04 | harden converges to baseline (retention 7, window, tag) → VALIDATED | PASS | logs/C04.log |
| C05 | restored instance: 3 SGs, retention 7, deletion protection, all source tags | PASS | logs/C05.log |
| C06 | password trap: precheck FAILS (restored DB has the old password) | PASS | logs/C06.log |
| C07 | fix-password → precheck OK | PASS | logs/C07.log |
| C07b | validate-pg: pg_settings restored == source | PASS | logs/C07b.log |
| C07c | validate-pg detects a changed parameter (work_mem), passes after reset | PASS | logs/C07c.log |
| C08 | compare-counts: orders old=100 vs restored=80 | PASS | logs/C08.log |
| C09 | DB verification SQL on restored | PASS | logs/C09.log |
| D01 | apply with RESTART_UNANNOTATED=false | PASS | logs/D01.log |
| D02 | K8s Secret POSTGRES_DB_HOST = restored endpoint | PASS | logs/D02.log |
| D03 | Reloader restarted app-a and app-b | PASS | logs/D03.log |
| D04 | app-c reported as UNANNOTATED → SKIPPED | PASS | logs/D04.log |
| D05 | Reloader did NOT touch app-c (same pod, same generation) | PASS | logs/D05.log |
| D06 | sessions: restored = app-a,app-b · old = app-c | PASS | logs/D06.log |
| D07 | dr-verify connections: TARGET has app-a (query must succeed) | PASS | logs/D07.log |
| D07a | secret-consumers tool refuses without --context | PASS | logs/D07a.log |
| D07b | secret-consumers tool refuses a cluster that is not env=prod | PASS | logs/D07b.log |
| D07c | check: app-c STALE, app-a/app-b UP-TO-DATE (exit 1) | PASS | logs/D07c.log |
| D07d | restart-stale restarts ONLY app-c (app-a/app-b generation unchanged) | PASS | logs/D07d.log |
| D07e | check after restart: all UP-TO-DATE (exit 0), app-c on restored | PASS | logs/D07e.log |
| D08 | rollback with RESTART_UNANNOTATED=true → secret back to old | PASS | logs/D08.log |
| D09 | after rollback all 3 apps on old, none on restored | PASS | logs/D09.log |
| D10 | re-apply with RESTART_UNANNOTATED=true | PASS | logs/D10.log |
| D11 | app-c restarted manually (UNANNOTATED → manual rollout restart) | PASS | logs/D11.log |
| D12 | all 3 apps on restored, 0 on old | PASS | logs/D12.log |
| E01 | fence F1 readonly on old | PASS | logs/E01.log |
| E02 | old DB new sessions are read-only | PASS | logs/E02.log |
| E03 | fence F2 quarantine SG on old | PASS | logs/E03.log |
| E04 | old instance SGs = [quarantine] | PASS | logs/E04.log |
| E05 | un-fence restores 3 SGs + read-write | PASS | logs/E05.log |
| E06 | suspend CronJobs | PASS | logs/E06.log |
| E07 | resume CronJobs | PASS | logs/E07.log |
| F01 | S2 promote replica + wait-promoted (standalone + writable) | PASS | logs/F01.log |
| F02 | S4 PITR latest → restore request from baseline with 3 SGs | PASS | logs/F02.log |
| F03 | S4 PITR: wait + harden → VALIDATED against the baseline | PASS | logs/F03.log |
| G00 | recorded session: transcript + history, password redacted, REFUSED shown, synced to S3 | **FAIL** | logs/G00.log |
| G00b | audit log commands.jsonl: every call, secret-string redacted, refusals recorded | PASS | logs/G00b.log |
| G01 | phase timer + summary | PASS | logs/G01.log |
| G01b | dr_phase end syncs the evidence folder to S3 (timeline already off the machine) | PASS | logs/G01b.log |
| G02 | collect evidence → manifest uploaded to the evidence bucket | PASS | logs/G02.log |
| G03 | KPI report: RPO from snapshot time, RTO ~20 min | PASS | logs/G03.log |
| G04 | SSM Automation documents accepted (create-document) | PASS | logs/G04.log |
| G05 | tracker CSV generated for every runbook | PASS | logs/G05.log |
| H01 | show: both host keys = old primary, not managed by ESO | PASS | logs/H01.log |
| H02 | refuses to patch an ESO-owned Secret (ESO would revert it) | PASS | logs/H02.log |
| H03 | refuses an ID with spaces / bad characters | PASS | logs/H03.log |
| H04 | preflight (SECRET_MODE=k8s): host keys present, not ESO-owned | PASS | logs/H04.log |
| H05 | cutover #1 (id DR-20261004-0650-local-S3): BOTH keys → restored, annotations cutover-id + db-id | PASS | logs/H05.log |
| H06 | ledger entry #1: id, old→new endpoint per key, old/new DB identifier | PASS | logs/H06.log |
| H07 | Reloader restarted app-d; app-e (no annotation) SKIPPED | PASS | logs/H07.log |
| H08 | stale check finds app-e (HOST2), restart-stale → both apps on restored | PASS | logs/H08.log |
| H09 | Reloader ALERT webhook received the reload (secret, app-d, cluster info) | PASS | logs/H09.log |
| H10 | cutover #2 (id DR-20261004-0650-local-S2): → promoted replica | PASS | logs/H10.log |
| H11 | failback to the endpoint before #1 (id DR-20261004-0650-local-FB-S3S4 → ref DR-20261004-0650-local-S3): both keys + both apps on old primary | PASS | logs/H11.log |
| H12 | history: #1 cutover, #2 cutover, #3 failback (ref #1) — who/when/from→to | PASS | logs/H12.log |
| H13 | rollback undoes the latest change (failback) → replica again | PASS | logs/H13.log |
| H14 | rollback refuses when the Secret was changed outside the ledger | PASS | logs/H14.log |

**PASS=85 FAIL=1** · DR_ID=DR-localtest-20261004064443 · 2026-10-04T06:50:22Z

> G00 failed only at its final S3 check: `aws s3 ls | grep -q` under pipefail → SIGPIPE ("Broken pipe") once the bucket held ~100 objects. Test fixed (grep without -q); the session/redaction/sync behaviour itself passed and the fixed check was verified against this run's evidence.
