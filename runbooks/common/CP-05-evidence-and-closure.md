# CP-05 — Evidence, RTO/RPO and Closure

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| CP05-S01 | Record the RPO inputs on the timeline (see [docs/04](../../docs/04-rpo-rto-measurement.md)): S1 → `dr_mark RPO_ZERO` (synchronous standby); S2 → `RPO_LAST_REPLICATED` (heartbeat on the promoted DB) + `RPO_LAST_PRIMARY_COMMIT`; S3 → `dr_mark RPO_SNAPSHOT "value=<SnapshotCreateTime>"`; S4 → `dr_mark RPO_RESTORE_TS "value=<restore-time>"` (plus `DAMAGE_STOPPED` / `FENCE` markers, which bound the loss window) | DBA | 2 | Markers present |
| CP05-S02 | Collect evidence + KPIs: `./automation/scripts/dr-collect-evidence.sh` (CloudTrail, RDS events, describe before/after, secret version stages (no values), k8s rollouts, SQL outputs, timeline, manifest + SHA-256 → S3 Object Lock) | Scribe | 10 | `EVIDENCE: s3://… sha256=…` posted in the channel |
| CP05-S03 | Post the KPI table (`rto-rpo-report.md`) in the incident channel and the ticket | Scribe | 1 | Posted |
| CP05-S04 | Raise the **FB / normalisation change** for the scenario (see the [catalogue](../README.md)) with an owner and date | IC | 2 | Change ID recorded |
| CP05-S05 | Schedule the **post-incident review** ([CP-06](CP-06-post-incident-review.md)): PROD ≤ 5 business days; UAT ≤ 10; DEV optional | IC | 1 | Meeting booked |

**Minimum evidence set** (collected by `dr-collect-evidence.sh`; nothing typed or screenshotted by hand during the RTO clock, F10):

| Evidence | Source | Auto |
|---|---|---|
| Timeline with T0…T10 + phase durations (UTC) | `timeline.jsonl`, `rto-rpo-report.md` | ✔ |
| RPO reference (`SnapshotCreateTime` / restore time / heartbeat) | timeline markers | ✔ |
| Recovery API calls + approvals | CloudTrail, SSM execution | ✔ |
| Instance configuration after recovery (SGs, retention, parity) | `db/describe-*.json`, parity output | ✔ |
| Secret version change (no values) + K8s rollout records | `aws/secret-*`, `k8s/*` | ✔ |
| DB verification + row counts | `db-post.txt`, `counts.txt` | ✔ |
| E2E result (transaction ID, screenshot with clock) | `app/` per the E2E playbook | manual, after T9 |
| Communications sent | `comms/sent-messages.md` | manual / incident tool |

**Closure checklist** (the incident cannot close without it): every gate decision recorded; comms log complete; evidence manifest uploaded; parity diff empty or accepted (CP-03); FB change raised; deviations listed, each with a ticket.
