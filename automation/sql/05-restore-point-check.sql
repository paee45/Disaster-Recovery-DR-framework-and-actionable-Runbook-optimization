-- 05-restore-point-check.sql — CP02-S02 for S3/S4: is the restored data at the expected point, and is the bad change absent?
--   psql "$TARGET_DSN" -v cutoff="'2026-10-04T10:15:41Z'" -f automation/sql/05-restore-point-check.sql
-- TODO(capstone): replace the business checks with your key tables / known-bad markers.
\set ON_ERROR_STOP on
SELECT 'INFO cutoff(expected restore point) = ' || :cutoff::timestamptz;
SELECT 'INFO heartbeat ts = ' || coalesce((SELECT ts::text FROM dr.heartbeat WHERE id = 1), 'n/a')
       || CASE WHEN (SELECT ts FROM dr.heartbeat WHERE id = 1) > :cutoff::timestamptz
               THEN '  FAIL newer than cutoff' ELSE '  OK' END;

-- Latest write per table that has a timestamp column: must be <= cutoff (+ small clock skew)
SELECT format('SELECT %L || '' max='' || coalesce(max(%I)::text, ''empty'') || CASE WHEN max(%I) > %L::timestamptz + interval ''5 seconds'' THEN ''  FAIL newer than cutoff'' ELSE ''  OK'' END FROM %I.%I;',
              table_schema || '.' || table_name || '.' || column_name, column_name, column_name, :cutoff, table_schema, table_name)
FROM information_schema.columns
WHERE column_name IN ('updated_at', 'created_at') AND data_type LIKE 'timestamp%'
  AND table_schema NOT IN ('pg_catalog', 'information_schema', 'dr')
ORDER BY 1 \gexec

-- Business assertions (examples):
-- SELECT CASE WHEN count(*) > 0 THEN 'OK   orders present: ' || count(*) ELSE 'FAIL orders empty' END FROM app.orders;
-- SELECT CASE WHEN to_regclass('app.customers') IS NOT NULL THEN 'OK   dropped table is back' ELSE 'FAIL app.customers missing' END;
