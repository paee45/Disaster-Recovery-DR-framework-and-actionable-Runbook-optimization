-- 00-heartbeat.sql — RPO heartbeat. Create once on the PRIMARY (it replicates to the DR replica).
-- Writer: K8s CronJob / pg_cron every second-ish (see automation/k8s/heartbeat-writer.yaml).
CREATE SCHEMA IF NOT EXISTS dr;
CREATE TABLE IF NOT EXISTS dr.heartbeat (
  id  int PRIMARY KEY,
  ts  timestamptz NOT NULL,
  src text NOT NULL DEFAULT current_setting('application_name', true)
);
-- Writer statement (executed in a loop by the writer; it also logs each successful commit timestamp to stdout):
--   INSERT INTO dr.heartbeat(id, ts) VALUES (1, clock_timestamp())
--   ON CONFLICT (id) DO UPDATE SET ts = EXCLUDED.ts
--   RETURNING ts;
-- Least privilege: GRANT USAGE ON SCHEMA dr TO app_user; GRANT INSERT, UPDATE, SELECT ON dr.heartbeat TO app_user;  -- writer uses the app secret (follows cutovers)
