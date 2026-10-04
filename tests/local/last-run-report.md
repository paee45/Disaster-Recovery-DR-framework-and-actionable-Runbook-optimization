# Local test run — 2026-10-04 (k3s v1.31.4 · LocalStack 4.0 · moto 5.2.3 · ESO 2.11.0 · Reloader 1.4.22 · Postgres 16)

| # | Test | Result | Log |
|---|---|---|---|
| A01 | guard passes with the pinned profile + context | PASS | logs/A01.log |
| A02 | wrong AWS profile (other account) is refused | PASS | logs/A02.log |
| A03 | unknown kube context is refused | PASS | logs/A03.log |
| A04 | decoy context (other cluster) is refused | PASS | logs/A04.log |
| A05 | cluster whose identity says env=uat is refused | PASS | logs/A05.log |
| A06 | kubectl wrapper ignores current-context (decoy) and uses EKS_CONTEXT | PASS | logs/A06.log |
| A07 | local endpoint-map seam refused outside DR_ENV=local | PASS | logs/A07.log |
| A08 | PROD confirmation blocks non-interactive changes (no DR_ASSUME_YES) | PASS | logs/A08.log |
| A09 | aws wrapper pins profile: caller account = 000000000000 | PASS | logs/A09.log |
| B01 | dr-env-check.sh S3 → PASS | PASS | logs/B01.log |
| B02 | inventory: app-a/app-b Reloader YES, app-c NO, CronJob listed | PASS | logs/B02.log |
| B03 | preflight restore → PASS (inputs copied from source) | PASS | logs/B03.log |
| B04 | preflight replica → PASS | PASS | logs/B04.log |
| C01 | list-snapshots | PASS | logs/C01.log |
| C02 | restore snapshot → copies ALL 3 security groups from source | PASS | logs/C02.log |
| C03 | wait until available (progress + T5) | PASS | logs/C03.log |
| C04 | harden: backup retention 7 + deletion protection | PASS | logs/C04.log |
| C05 | restored instance has 3 SGs (exercise bug F3 fixed) | PASS | logs/C05.log |
| C06 | password trap: precheck FAILS (restored DB has the old password) | PASS | logs/C06.log |
| C07 | fix-password → precheck OK | PASS | logs/C07.log |
| C08 | compare-counts: orders old=100 vs restored=80 | PASS | logs/C08.log |
| C09 | DB verification SQL on restored | PASS | logs/C09.log |
| D01 | apply with RESTART_UNANNOTATED=false | PASS | logs/D01.log |
| D02 | K8s Secret POSTGRES_DB_HOST = restored endpoint | PASS | logs/D02.log |
| D03 | Reloader restarted app-a and app-b | PASS | logs/D03.log |
| D04 | app-c reported as UNANNOTATED → SKIPPED | PASS | logs/D04.log |
| D05 | Reloader did NOT touch app-c (same pod, same generation) | PASS | logs/D05.log |
| D06 | sessions: restored = app-a,app-b · old = app-c | PASS | logs/D06.log |
| D07 | dr-verify connections: TARGET has app-a (query must succeed) | PASS | logs/D07.log |
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
| F02 | S4 PITR latest → hardened restore with 3 SGs | PASS | logs/F02.log |
| G01 | phase timer + summary | PASS | logs/G01.log |
| G02 | collect evidence → manifest uploaded to the evidence bucket | PASS | logs/G02.log |
| G03 | KPI report: RPO from snapshot time, RTO ~20 min | PASS | logs/G03.log |
| G04 | SSM Automation documents accepted (create-document) | PASS | logs/G04.log |
| G05 | tracker CSV generated for every runbook | PASS | logs/G05.log |

**PASS=48 FAIL=0** · DR_ID=DR-localtest-20261004033316 · 2026-10-04T03:39:41Z
