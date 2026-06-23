-- 08_results.sql
-- Final summary report.  Run after all bench scripts have completed.
-- Outputs a human-readable comparison table for sizes and
-- (if bench_results was populated by the shell script) timing medians.

\echo ''
\echo '══════════════════════════════════════════════════════════════════'
\echo '  FTS uid experiment — summary'
\echo '══════════════════════════════════════════════════════════════════'

-- ── Document count ────────────────────────────────────────────────────────────
\echo ''
\echo '--- Corpus ---'
SELECT
    count(*)                              AS total_docs,
    pg_size_pretty(pg_total_relation_size('docs')) AS table_total_size
FROM docs;

-- ── Lexicon ───────────────────────────────────────────────────────────────────
\echo ''
\echo '--- Lexicon ---'
SELECT
    count(*)           AS distinct_lexemes,
    sum(ndoc)          AS total_lexeme_occurrences,
    max(id)            AS max_id,
    encode_id(max(id)) AS max_encoded_key
FROM lex_dict;

-- ── Column sizes ─────────────────────────────────────────────────────────────
\echo ''
\echo '--- Heap column sizes ---'
SELECT
    'tsv (baseline)'             AS column_name,
    pg_size_pretty(sum(pg_column_size(tsv)))      AS heap_size,
    round(avg(pg_column_size(tsv)))               AS avg_bytes_per_row
FROM docs
UNION ALL
SELECT
    'tsv_int (int-proxy)',
    pg_size_pretty(sum(pg_column_size(tsv_int))),
    round(avg(pg_column_size(tsv_int)))
FROM docs;

\echo ''
\echo '--- Heap size ratio ---'
SELECT
    round(100.0 * sum(pg_column_size(tsv_int)) / sum(pg_column_size(tsv)), 1)
        AS tsvint_pct_of_baseline,
    round((1.0 - sum(pg_column_size(tsv_int))::numeric / sum(pg_column_size(tsv))) * 100, 1)
        AS size_reduction_pct
FROM docs;

-- ── Index sizes ───────────────────────────────────────────────────────────────
\echo ''
\echo '--- Index sizes ---'
SELECT
    indexname,
    pg_size_pretty(pg_relation_size(indexname::regclass)) AS index_size
FROM pg_indexes
WHERE tablename = 'docs'
  AND indexname IN (
      'docs_tsv_gin', 'docs_tsv_gist',
      'docs_tsvint_gin', 'docs_tsvint_gist'
  )
ORDER BY indexname;

-- ── TOAST check ───────────────────────────────────────────────────────────────
\echo ''
\echo '--- TOAST table (if any) ---'
SELECT
    c2.relname                                    AS toast_table,
    pg_size_pretty(pg_total_relation_size(c2.oid)) AS toast_size
FROM pg_class c1
JOIN pg_class c2 ON c2.oid = c1.reltoastrelid
WHERE c1.relname = 'docs';

-- ── Timing medians (from bench_results populated by shell script) ─────────────
\echo ''
\echo '--- Timing medians (ms) ---'
SELECT
    phase,
    query_type,
    count(*)                     AS runs,
    round((percentile_cont(0.5) WITHIN GROUP (ORDER BY exec_ms))::numeric, 2) AS median_ms,
    round(min(exec_ms)::numeric, 2)       AS min_ms,
    round(max(exec_ms)::numeric, 2)       AS max_ms,
    round(stddev(exec_ms)::numeric, 2)    AS stddev_ms,
    round(avg(hit_blocks)::numeric)       AS avg_hit_blk,
    round(avg(read_blocks)::numeric)      AS avg_read_blk
FROM bench_results
GROUP BY phase, query_type
ORDER BY phase, query_type;

\echo ''
\echo '══════════════════════════════════════════════════════════════════'
\echo '08_results.sql: done'
