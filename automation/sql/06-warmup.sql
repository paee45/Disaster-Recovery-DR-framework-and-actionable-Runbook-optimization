-- 06-warmup.sql — CP02-S08: restored RDS volumes lazy-load blocks from S3; first reads are slow.
-- Pre-load the hottest relations (tables + their indexes). pg_prewarm is supported on RDS PostgreSQL.
-- Run on TARGET_DB after restore, ideally BEFORE the cutover (S3/S4 P2-S07). Duration ~ size of the listed relations.
CREATE EXTENSION IF NOT EXISTS pg_prewarm;
\timing on
-- Top 20 relations by size in the app schemas (adjust the filter / use a fixed list of critical tables):
SELECT c.oid::regclass AS relation, pg_size_pretty(pg_relation_size(c.oid)) AS size, pg_prewarm(c.oid) AS blocks
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'i') AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast', 'dr')
ORDER BY pg_relation_size(c.oid) DESC
LIMIT 20;
-- Alternative for a full-volume warm-up (large DBs): run in parallel sessions per table:
--   SELECT count(*) FROM <table>;   (touches every heap block)
