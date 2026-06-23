-- 04_encode.sql
-- Builds the int-proxy tsvector column (tsv_int):
--   • Each lexeme string is replaced by its 4-char base62 id from lex_dict.
--   • Positions and weights are preserved exactly.
-- Then builds GIN and GIST indexes on tsv_int.
--
-- Key notes on tsvector text format:
--   lexeme[:pos[weight],pos[weight],...]
--   Weight 'D' (the default) is NOT written; 'A','B','C' are written explicitly.
--   ::tsvector cast sorts and validates lexemes automatically.
--
-- unnest(tsvector) returns setof (lexeme text, positions smallint[], weights text[])
-- where each weight element is 'A','B','C', or 'D'.

\timing on
 
-- ── Per-row encoding function ──────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION tsv_to_int(tsv tsvector) RETURNS tsvector
LANGUAGE sql STABLE
AS $$
    SELECT string_agg(
        d.encoded ||
        CASE
            WHEN u.positions IS NOT NULL AND array_length(u.positions, 1) > 0
            THEN ':' || (
                    SELECT string_agg(
                        u.positions[i]::text ||
                        CASE WHEN u.weights[i] = 'D' THEN '' ELSE u.weights[i] END,
                        ',' ORDER BY i
                    )
                    FROM generate_subscripts(u.positions, 1) AS i
                 )
            ELSE ''
        END,
        ' '
    )::tsvector
    FROM unnest(tsv) AS u
    JOIN lex_dict d ON d.lexeme = u.lexeme;
$$;

-- ── Add column and populate ────────────────────────────────────────────────────

ALTER TABLE docs ADD COLUMN IF NOT EXISTS tsv_int tsvector;

\echo 'Populating tsv_int (batch UPDATE, may take several minutes)...'

-- Batch by 50 000 rows to keep transaction size manageable and allow progress monitoring.
DO $$
DECLARE
    batch_size  CONSTANT int := 50000;
    total_rows  bigint;
    processed   bigint := 0;
    lo          bigint;
    hi          bigint;
BEGIN
    SELECT count(*) INTO total_rows FROM docs;
    RAISE NOTICE 'Total rows: %', total_rows;

    FOR lo IN
        SELECT gs FROM generate_series(1, total_rows, batch_size) AS gs
    LOOP
        hi := lo + batch_size - 1;
        UPDATE docs
        SET    tsv_int = tsv_to_int(tsv)
        WHERE  id BETWEEN lo AND hi;

        processed := processed + batch_size;
        RAISE NOTICE 'Processed ~%/% rows', least(processed, total_rows), total_rows;
    END LOOP;
END;
$$;

-- ── Indexes ────────────────────────────────────────────────────────────────────

\echo 'Building GIN index on tsv_int...'
CREATE INDEX IF NOT EXISTS docs_tsvint_gin  ON docs USING GIN  (tsv_int);

\echo 'Building GIST index on tsv_int...'
CREATE INDEX IF NOT EXISTS docs_tsvint_gist ON docs USING GIST (tsv_int);

ANALYZE docs;

-- ── Size report ────────────────────────────────────────────────────────────────

\echo ''
\echo '=== Int-proxy sizes ==='
SELECT
    pg_size_pretty(sum(pg_column_size(tsv_int)))             AS tsvint_heap,
    pg_size_pretty(pg_relation_size('docs_tsvint_gin'))       AS gin_index,
    pg_size_pretty(pg_relation_size('docs_tsvint_gist'))      AS gist_index
FROM docs;

\echo ''
\echo '=== Comparison: baseline vs int-proxy heap size ==='
SELECT
    pg_size_pretty(sum(pg_column_size(tsv)))     AS tsv_heap,
    pg_size_pretty(sum(pg_column_size(tsv_int))) AS tsvint_heap,
    round(100.0 * sum(pg_column_size(tsv_int))
               / sum(pg_column_size(tsv)), 1)    AS pct_of_baseline
FROM docs;

\timing off
\echo '04_encode.sql: done'
