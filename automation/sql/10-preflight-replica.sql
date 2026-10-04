-- 10-preflight-replica.sql — run on the DR REPLICA (P1-S06 and P2-S05, the final capture before promotion).
-- Output is the RPO evidence: last received/replayed LSN and last replayed commit timestamp.
SELECT 'observed_at',          clock_timestamp()::text;
SELECT 'in_recovery',          pg_is_in_recovery()::text;
SELECT 'receive_lsn',          coalesce(pg_last_wal_receive_lsn()::text, 'n/a');
SELECT 'replay_lsn',           coalesce(pg_last_wal_replay_lsn()::text, 'n/a');
SELECT 'replay_gap_bytes',     coalesce(pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn())::text, 'n/a');
SELECT 'last_replayed_commit', coalesce(pg_last_xact_replay_timestamp()::text, 'n/a');
SELECT 'replay_delay',         coalesce((clock_timestamp() - pg_last_xact_replay_timestamp())::text, 'n/a');
SELECT 'heartbeat_ts',         coalesce((SELECT ts::text FROM dr.heartbeat WHERE id = 1), 'n/a');
SELECT 'heartbeat_age',        coalesce((SELECT (clock_timestamp() - ts)::text FROM dr.heartbeat WHERE id = 1), 'n/a');
-- Size sanity (catalog estimates are replicated; pg_stat_* counters are NOT maintained on a standby)
SELECT 'reltuples:' || n.nspname || '.' || c.relname, c.reltuples::bigint::text
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r' AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'dr')
ORDER BY c.reltuples DESC LIMIT 15;
