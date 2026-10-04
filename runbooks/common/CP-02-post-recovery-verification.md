# CP-02 — Post-Recovery Verification

**Used by:** every scenario, after the DB is writable (S1) or after CP-01 (S2–S4). **Budget:** 15 min to T9.

| ID | Step | Owner | ⏱ | Expected / verify |
|---|---|---|---|---|
| CP02-S01 | **DB checks** on the current primary: `dr_run db-post psql "$TARGET_DSN" -f automation/sql/20-postfailover-verify.sql` (not in recovery, not read-only, write probe, invalid indexes, leftover slots, connection headroom) | DBA | 3 | All `OK` |
| CP02-S02 | **Restore-point validation** (S3/S4 only): `psql "$TARGET_DSN" -v cutoff="'<restore time>'" -f automation/sql/05-restore-point-check.sql`. The latest business timestamps must match the expected restore point, and the bad data (for a data incident) must be **absent** | DBA + App owner | 3 | App owner signs off: "data as of <ts>, bad change absent" |
| CP02-S03 | **App connections land on TARGET_DB**: `./automation/scripts/dr-verify.sh connections` (counts `pg_stat_activity` by `application_name` on TARGET and **OLD** instances) | DBA | 2 | TARGET has the expected consumers; **OLD has 0 app sessions** |
| CP02-S04 | **App deep health**: `./automation/scripts/dr-verify.sh app` (readiness/deep-health endpoints of critical services) | App owner | 2 | All 200 |
| CP02-S05 | **Synthetic business transactions** (login → read → create/save → background job processed) | App owner | 5 | All pass. The first of 3 consecutive greens = `dr_mark T9` |
| CP02-S06 | **Error/latency SLO** for 15 min (5xx rate, p95, DB errors such as `could not connect` / `read-only transaction`) | App owner | 15 | Within SLO |
| CP02-S07 | **Async paths**: queues draining, CronJobs resumed (CP01-S09), integrations (in/outbound) processing | App owner | 5 | Backlog trending to 0 |
| CP02-S08 | **Performance after restore** (S3/S4): restored volumes **lazy-load from S3**, so the first reads are slow. Warm the hot tables: `psql "$TARGET_DSN" -f automation/sql/06-warmup.sql` (`pg_prewarm`) and watch `ReadLatency`/`DiskQueueDepth` | DBA | 10–60 | Latency back to baseline |
| CP02-G4 ⛳ | **Declare service restored** (IC) → `dr_mark T10` → send [Services Restored] comms | IC | 1 | Recorded |
