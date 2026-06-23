-- 06_bench_search.sql
-- Builds the query workload and measures @@ search performance.
--
-- Query classes:
--   single  — one lexeme (top-500 by doc frequency)
--   and2    — two-term AND query  (200 pairs from top-400)
--   phrase  — two-term phrase <-> (200 pairs from top-400)
--
-- For each class, four variants are timed:
--   (tsv / tsv_int) × (GIN / GIST)
--
-- Measurements use EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) so the shell
-- script can extract "Execution Time" and buffer hit/read counts via jq.
-- Each query is run 5 times; median is taken by the shell script.

\timing on

-- ── Build query workload ───────────────────────────────────────────────────────

DROP TABLE IF EXISTS bench_queries;
CREATE TABLE bench_queries (
    qid        serial PRIMARY KEY,
    qtype      text NOT NULL,          -- 'single' | 'and2' | 'phrase'
    label      text NOT NULL,          -- human-readable, for reports
    q_orig     tsquery NOT NULL,       -- for tsv  (english config)
    q_int      tsquery NOT NULL        -- for tsv_int (simple config, encoded ids)
);

-- single-term queries
INSERT INTO bench_queries (qtype, label, q_orig, q_int)
SELECT
    'single',
    lexeme,
    to_tsquery('english', lexeme),
    to_tsquery('simple',  encoded)
FROM lex_dict
ORDER BY ndoc DESC
LIMIT 500;

-- and2: pairs from top-400 (pick 200 disjoint pairs by interleaving)
INSERT INTO bench_queries (qtype, label, q_orig, q_int)
SELECT
    'and2',
    a.lexeme || ' & ' || b.lexeme,
    a.q_orig && b.q_orig,
    a.q_int  && b.q_int
FROM (
    SELECT lexeme, encoded,
           to_tsquery('english', lexeme) AS q_orig,
           to_tsquery('simple',  encoded) AS q_int,
           row_number() OVER (ORDER BY ndoc DESC) AS rn
    FROM lex_dict
    ORDER BY ndoc DESC LIMIT 400
) a
JOIN (
    SELECT lexeme, encoded,
           to_tsquery('english', lexeme) AS q_orig,
           to_tsquery('simple',  encoded) AS q_int,
           row_number() OVER (ORDER BY ndoc DESC) AS rn
    FROM lex_dict
    ORDER BY ndoc DESC LIMIT 400
) b ON b.rn = a.rn + 200
WHERE a.rn <= 200;

-- phrase: same pairs as <->
INSERT INTO bench_queries (qtype, label, q_orig, q_int)
SELECT
    'phrase',
    a.lexeme || ' <-> ' || b.lexeme,
    to_tsquery('english', a.lexeme || ' <-> ' || b.lexeme),
    to_tsquery('simple',  a.encoded || ' <-> ' || b.encoded)
FROM (
    SELECT lexeme, encoded,
           row_number() OVER (ORDER BY ndoc DESC) AS rn
    FROM lex_dict ORDER BY ndoc DESC LIMIT 400
) a
JOIN (
    SELECT lexeme, encoded,
           row_number() OVER (ORDER BY ndoc DESC) AS rn
    FROM lex_dict ORDER BY ndoc DESC LIMIT 400
) b ON b.rn = a.rn + 200
WHERE a.rn <= 200;

\echo ''
\echo '=== Query workload ==='
SELECT qtype, count(*) FROM bench_queries GROUP BY qtype ORDER BY qtype;

-- ── Warm-up (discarded) ────────────────────────────────────────────────────────
-- Run the first query of each type 3× to warm shared_buffers before measuring.

\echo 'Warm-up runs...'

DO $$
DECLARE
    q_orig tsquery;
    q_int  tsquery;
    dummy  bigint;
    i      int;
BEGIN
    SELECT bq.q_orig, bq.q_int INTO q_orig, q_int
    FROM bench_queries bq WHERE qtype = 'single' LIMIT 1;

    FOR i IN 1..3 LOOP
        SELECT count(*) INTO dummy FROM docs WHERE tsv     @@ q_orig;
        SELECT count(*) INTO dummy FROM docs WHERE tsv_int @@ q_int;
    END LOOP;
END;
$$;

-- ── Search benchmark: single-term, representative query ───────────────────────
-- The shell script will loop over multiple queries and parse JSON output.
-- Here we emit EXPLAIN JSON for one representative query of each type
-- so the file is self-contained and runnable interactively too.

\echo ''
\echo '=== EXPLAIN (ANALYZE, BUFFERS) – single-term, baseline GIN ==='
\set ECHO all

DO $$
DECLARE
    rec    record;
    plan   json;
BEGIN
    SELECT * INTO rec FROM bench_queries WHERE qtype = 'single' LIMIT 1;

    EXECUTE format(
        'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) '
        'SELECT count(*) FROM docs WHERE tsv @@ %L::tsquery',
        rec.q_orig::text
    ) INTO plan;

    RAISE NOTICE 'baseline GIN single: %', plan;

    EXECUTE format(
        'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) '
        'SELECT count(*) FROM docs WHERE tsv_int @@ %L::tsquery',
        rec.q_int::text
    ) INTO plan;

    RAISE NOTICE 'int-proxy GIN single: %', plan;
END;
$$;

-- ── Force GIST (disable bitmap/index scans selectively) ───────────────────────
-- PostgreSQL will pick GIN over GIST for exact matches by default.
-- To benchmark GIST we must disable the GIN indexes temporarily.

\echo ''
\echo '=== GIST search (GIN indexes dropped temporarily) ==='

DROP INDEX IF EXISTS docs_tsv_gin;
DROP INDEX IF EXISTS docs_tsvint_gin;

DO $$
DECLARE
    rec    record;
    plan   json;
BEGIN
    SELECT * INTO rec FROM bench_queries WHERE qtype = 'single' LIMIT 1;

    EXECUTE format(
        'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) '
        'SELECT count(*) FROM docs WHERE tsv @@ %L::tsquery',
        rec.q_orig::text
    ) INTO plan;
    RAISE NOTICE 'baseline GIST single: %', plan;

    EXECUTE format(
        'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) '
        'SELECT count(*) FROM docs WHERE tsv_int @@ %L::tsquery',
        rec.q_int::text
    ) INTO plan;
    RAISE NOTICE 'int-proxy GIST single: %', plan;
END;
$$;

-- Restore GIN indexes
\echo 'Restoring GIN indexes...'
CREATE INDEX IF NOT EXISTS docs_tsv_gin    ON docs USING GIN  (tsv);
CREATE INDEX IF NOT EXISTS docs_tsvint_gin ON docs USING GIN  (tsv_int);

\timing off
\echo '06_bench_search.sql: done'
