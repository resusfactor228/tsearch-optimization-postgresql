-- 00_setup.sql
-- Run once after CREATE DATABASE fts_bench.
-- Fixes session-level GUCs that must be identical for baseline and int-proxy runs.
-- DB-level settings (autovacuum=off) are applied from run_experiment.sh before this file.

SET jit                              = off;
SET max_parallel_workers_per_gather  = 0;
SET work_mem                         = '512MB';

-- Main corpus table
CREATE TABLE IF NOT EXISTS docs (
    id   bigserial PRIMARY KEY,
    body text      NOT NULL
);

-- Disable autovacuum on the experiment table to avoid interference during benchmarks
ALTER TABLE docs SET (autovacuum_enabled = false, toast.autovacuum_enabled = false);

-- Results accumulator (written by shell script via \copy or INSERT)
CREATE TABLE IF NOT EXISTS bench_results (
    ts          timestamptz DEFAULT now(),
    phase       text,          -- 'search_gin_baseline', 'rank_cd_int', etc.
    query_type  text,          -- 'single', 'and2', 'phrase'
    run_no      int,
    exec_ms     numeric,
    hit_blocks  bigint,
    read_blocks bigint
);

\echo '00_setup.sql: done'
