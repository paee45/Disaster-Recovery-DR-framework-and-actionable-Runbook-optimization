-- 15-planned-drain.sql — PLANNED promotion only (drills, FB-S2 option B), run on the current PRIMARY.
-- 1) Block new writes at DB level (belt and braces, in addition to scaling writers to 0):
--      ALTER DATABASE app SET default_transaction_read_only = on;
--      SELECT pg_terminate_backend(pid) FROM pg_stat_activity
--       WHERE datname = 'app' AND pid <> pg_backend_pid() AND usename <> 'rdsadmin' AND backend_type = 'client backend';
--    (Undo on the NEW primary after promotion: ALTER DATABASE app SET default_transaction_read_only = off;
--     the setting is replicated, so the promoted replica inherits it!)
-- 2) Force a WAL switch so the final records ship, then poll until bytes_behind = 0:
SELECT pg_switch_wal();
SELECT application_name, client_addr, state, sent_lsn, replay_lsn,
       pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS bytes_behind,
       replay_lag
FROM pg_stat_replication;
-- If the cross-region replica does not appear in pg_stat_replication in your setup, compare
-- pg_current_wal_lsn() here with pg_last_wal_replay_lsn() on the replica until equal.
SELECT pg_current_wal_lsn() AS primary_current_lsn;
