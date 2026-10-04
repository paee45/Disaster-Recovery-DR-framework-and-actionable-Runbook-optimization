-- 20-postfailover-verify.sql — run on the current/new PRIMARY (CP02-S01). Every line prints OK/FAIL.
\set ON_ERROR_STOP on
SELECT CASE WHEN NOT pg_is_in_recovery() THEN 'OK   not in recovery' ELSE 'FAIL still in recovery' END;
SELECT CASE WHEN current_setting('default_transaction_read_only') = 'off'
            THEN 'OK   default_transaction_read_only=off'
            ELSE 'FAIL default_transaction_read_only=on (planned drain leftover? ALTER DATABASE ... SET default_transaction_read_only = off)' END;
CREATE SCHEMA IF NOT EXISTS dr;
CREATE TABLE IF NOT EXISTS dr.write_probe(id bigserial PRIMARY KEY, ts timestamptz DEFAULT clock_timestamp(), note text);
INSERT INTO dr.write_probe(note) VALUES ('postfailover-verify');
SELECT 'OK   write probe committed at ' || max(ts) FROM dr.write_probe;
-- Last replicated heartbeat = RPO input. Record it: dr_mark RPO_LAST_REPLICATED "value=<ts>"
SELECT 'INFO last_replicated_heartbeat=' || coalesce((SELECT ts::text FROM dr.heartbeat WHERE id = 1), 'n/a');
SELECT CASE WHEN count(*) = 0 THEN 'OK   no invalid indexes' ELSE 'FAIL invalid indexes: ' || string_agg(indexrelid::regclass::text, ', ') END
FROM pg_index WHERE NOT indisvalid;
SELECT CASE WHEN count(*) = 0 THEN 'OK   no leftover replication slots' ELSE 'WARN replication slots present: ' || string_agg(slot_name, ', ') END
FROM pg_replication_slots;
SELECT 'INFO connections ' || count(*) || ' / max ' || current_setting('max_connections') FROM pg_stat_activity;
-- Business sanity: replace with your key tables and compare with the reltuples from 10-preflight-replica.sql
-- SELECT 'INFO orders_last_hour=' || count(*) FROM app.orders WHERE created_at > now() - interval '1 hour';
