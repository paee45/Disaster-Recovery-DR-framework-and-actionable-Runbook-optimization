-- 30-reconciliation-hints.sql — Phase 5 (P5-S02). Run on the OLD primary, started ISOLATED
-- (fenced SG, or restored from the pre-failback snapshot). Purpose: find writes that never reached the DR side.
-- :cutoff = last replicated heartbeat ts recorded on the new primary (RPO_LAST_REPLICATED).
--   psql "$OLD_DSN" -v cutoff="'2026-10-04T10:15:42.123Z'" -f 30-reconciliation-hints.sql
SELECT 'old_primary_last_heartbeat', ts FROM dr.heartbeat WHERE id = 1;

-- Generate a candidate query per table with a created_at/updated_at column:
SELECT format('SELECT %L AS tbl, count(*) FROM %I.%I WHERE %I > %s;',
              table_schema || '.' || table_name, table_schema, table_name, column_name, :'cutoff')
FROM information_schema.columns
WHERE column_name IN ('updated_at', 'created_at', 'modified_at')
  AND table_schema NOT IN ('pg_catalog', 'information_schema', 'dr')
ORDER BY table_schema, table_name;
-- Copy the generated statements, run them, then export the affected rows (\copy ... TO 'file.csv' CSV HEADER)
-- for the business owner to decide re-apply / discard. Tables without timestamps need a key-based diff
-- against the new primary (e.g. compare max(id) per table, or a dedicated diff tool).
