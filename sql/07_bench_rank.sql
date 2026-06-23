-- 07_bench_rank.sql
-- Measures ts_rank and ts_rank_cd performance.
--
-- Two sub-experiments:
--
-- A) Isolated throughput — rank every row in a fixed 2% TABLESAMPLE.
--    This removes index I/O noise and measures pure ranking CPU cost.
--    The TABLESAMPLE seed is fixed (REPEATABLE(42)) for reproducibility.
--
-- B) Realistic top-20 — WHERE tsv @@ q ORDER BY rank DESC LIMIT 20.
--    This is the end-to-end latency users actually see.
--
-- We test ts_rank and ts_rank_cd separately because ts_rank_cd processes
-- cover density (requires position lists) and is typically 2-3× slower.

\timing on

-- ── A: Isolated throughput ────────────────────────────────────────────────────

\echo '=== A: Isolated ranking throughput (TABLESAMPLE 2%) ==='

CREATE TEMP TABLE rank_sample AS
    SELECT tsv, tsv_int
    FROM   docs TABLESAMPLE SYSTEM (2) REPEATABLE (42);

ANALYZE rank_sample;
SELECT count(*) AS sample_rows FROM rank_sample;

-- ts_rank — baseline
\echo 'A1: ts_rank baseline...'
DO $$
DECLARE
    q_orig tsquery;
    q_int  tsquery;
BEGIN
    SELECT bq.q_orig, bq.q_int INTO q_orig, q_int
    FROM bench_queries WHERE qtype = 'single' ORDER BY qid LIMIT 1;

    RAISE NOTICE 'ts_rank baseline:';
    EXECUTE format(
        'EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) '
        'SELECT sum(ts_rank(tsv, %L::tsquery)) FROM rank_sample',
        q_orig::text
    );
END;
$$;

EXPLAIN (ANALYZE, BUFFERS)
SELECT sum(ts_rank(tsv, q.q_orig))
FROM   rank_sample
CROSS JOIN (SELECT q_orig FROM bench_queries WHERE qtype = 'single' LIMIT 1) q;

-- ts_rank — int-proxy
\echo 'A2: ts_rank int-proxy...'
EXPLAIN (ANALYZE, BUFFERS)
SELECT sum(ts_rank(tsv_int, q.q_int))
FROM   rank_sample
CROSS JOIN (SELECT q_int FROM bench_queries WHERE qtype = 'single' LIMIT 1) q;

-- ts_rank_cd — baseline
\echo 'A3: ts_rank_cd baseline...'
EXPLAIN (ANALYZE, BUFFERS)
SELECT sum(ts_rank_cd(tsv, q.q_orig))
FROM   rank_sample
CROSS JOIN (SELECT q_orig FROM bench_queries WHERE qtype = 'single' LIMIT 1) q;

-- ts_rank_cd — int-proxy
\echo 'A4: ts_rank_cd int-proxy...'
EXPLAIN (ANALYZE, BUFFERS)
SELECT sum(ts_rank_cd(tsv_int, q.q_int))
FROM   rank_sample
CROSS JOIN (SELECT q_int FROM bench_queries WHERE qtype = 'single' LIMIT 1) q;

-- Repeat each with an and2 query (multiple terms -> more work per call)
\echo 'A5: ts_rank_cd baseline AND2...'
EXPLAIN (ANALYZE, BUFFERS)
SELECT sum(ts_rank_cd(tsv, q.q_orig))
FROM   rank_sample
CROSS JOIN (SELECT q_orig FROM bench_queries WHERE qtype = 'and2' LIMIT 1) q;

\echo 'A6: ts_rank_cd int-proxy AND2...'
EXPLAIN (ANALYZE, BUFFERS)
SELECT sum(ts_rank_cd(tsv_int, q.q_int))
FROM   rank_sample
CROSS JOIN (SELECT q_int FROM bench_queries WHERE qtype = 'and2' LIMIT 1) q;

-- ── B: Realistic top-20 ───────────────────────────────────────────────────────

\echo ''
\echo '=== B: Realistic top-20 (search + rank) ==='

-- B1: single-term ts_rank_cd, baseline
\echo 'B1: baseline, single, ts_rank_cd, top-20...'
EXPLAIN (ANALYZE, BUFFERS)
SELECT d.id, ts_rank_cd(d.tsv, q.q_orig) AS r
FROM   docs d
CROSS JOIN (SELECT q_orig FROM bench_queries WHERE qtype = 'single' LIMIT 1) q
WHERE  d.tsv @@ q.q_orig
ORDER  BY r DESC
LIMIT  20;

-- B2: single-term ts_rank_cd, int-proxy
\echo 'B2: int-proxy, single, ts_rank_cd, top-20...'
EXPLAIN (ANALYZE, BUFFERS)
SELECT d.id, ts_rank_cd(d.tsv_int, q.q_int) AS r
FROM   docs d
CROSS JOIN (SELECT q_int FROM bench_queries WHERE qtype = 'single' LIMIT 1) q
WHERE  d.tsv_int @@ q.q_int
ORDER  BY r DESC
LIMIT  20;

-- B3: and2 ts_rank_cd, baseline
\echo 'B3: baseline, and2, ts_rank_cd, top-20...'
EXPLAIN (ANALYZE, BUFFERS)
SELECT d.id, ts_rank_cd(d.tsv, q.q_orig) AS r
FROM   docs d
CROSS JOIN (SELECT q_orig FROM bench_queries WHERE qtype = 'and2' LIMIT 1) q
WHERE  d.tsv @@ q.q_orig
ORDER  BY r DESC
LIMIT  20;

-- B4: and2 ts_rank_cd, int-proxy
\echo 'B4: int-proxy, and2, ts_rank_cd, top-20...'
EXPLAIN (ANALYZE, BUFFERS)
SELECT d.id, ts_rank_cd(d.tsv_int, q.q_int) AS r
FROM   docs d
CROSS JOIN (SELECT q_int FROM bench_queries WHERE qtype = 'and2' LIMIT 1) q
WHERE  d.tsv_int @@ q.q_int
ORDER  BY r DESC
LIMIT  20;

\timing off
\echo '07_bench_rank.sql: done'
