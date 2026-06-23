-- 02_baseline.sql
-- Adds a STORED tsvector column and builds GIN + GIST indexes on it.
-- Measures and prints sizes immediately after creation.
--
-- Prerequisite: docs table is populated (run 01 corpus load first).

\timing on

ALTER TABLE docs
    ADD COLUMN IF NOT EXISTS tsv tsvector
    GENERATED ALWAYS AS (to_tsvector('english', body)) STORED;

\echo 'tsvector column added, building GIN index...'
CREATE INDEX IF NOT EXISTS docs_tsv_gin  ON docs USING GIN  (tsv);

\echo 'GIN done, building GIST index...'
CREATE INDEX IF NOT EXISTS docs_tsv_gist ON docs USING GIST (tsv);

ANALYZE docs;

\echo ''
\echo '=== Baseline sizes ==='
SELECT
    pg_size_pretty(sum(pg_column_size(tsv)))               AS tsv_heap,
    pg_size_pretty(pg_relation_size('docs_tsv_gin'))        AS gin_index,
    pg_size_pretty(pg_relation_size('docs_tsv_gist'))       AS gist_index,
    pg_size_pretty(pg_total_relation_size('docs'))          AS docs_total
FROM docs;

-- TOAST breakdown (tsvector often spills to TOAST)
SELECT
    relname,
    pg_size_pretty(pg_total_relation_size(oid)) AS size
FROM pg_class
WHERE relname IN ('docs', 'docs_tsv_gin', 'docs_tsv_gist')
   OR relname LIKE 'pg_toast_%'
    AND oid IN (
        SELECT reltoastrelid FROM pg_class WHERE relname = 'docs'
    )
ORDER BY pg_total_relation_size(oid) DESC;

\timing off
\echo '02_baseline.sql: done'
