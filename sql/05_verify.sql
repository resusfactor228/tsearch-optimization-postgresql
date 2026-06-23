-- 05_verify.sql
-- Equivalence checks: tsv and tsv_int must represent the same documents.
-- If any check fails, the benchmark results are meaningless.

\echo '=== Verification ==='

-- 1. Every row must have tsv_int populated
SELECT count(*) AS null_tsvint_rows
FROM docs
WHERE tsv_int IS NULL;
-- Expected: 0

-- 2. Lexeme count per document must match
SELECT count(*) AS lexeme_count_mismatch
FROM docs
WHERE array_length(tsvector_to_array(tsv), 1)
   <> array_length(tsvector_to_array(tsv_int), 1);
-- Expected: 0

-- 3. For the top-20 most frequent lexemes, the hit-count via @@ must match
WITH top_lexemes AS (
    SELECT lexeme, encoded
    FROM   lex_dict
    ORDER  BY ndoc DESC
    LIMIT  20
)
SELECT
    l.lexeme,
    l.encoded,
    (SELECT count(*) FROM docs d
     WHERE  d.tsv     @@ to_tsquery('english', l.lexeme))  AS n_orig,
    (SELECT count(*) FROM docs d
     WHERE  d.tsv_int @@ to_tsquery('simple',  l.encoded)) AS n_int,
    (SELECT count(*) FROM docs d
     WHERE  d.tsv     @@ to_tsquery('english', l.lexeme))
    =
    (SELECT count(*) FROM docs d
     WHERE  d.tsv_int @@ to_tsquery('simple',  l.encoded)) AS match
FROM top_lexemes l;
-- Expected: match = true for all rows

-- 4. Two-term AND query: result sets must be identical for 3 pairs
WITH pairs AS (
    SELECT
        a.lexeme || ' & ' || b.lexeme                         AS q_str,
        (a.q_orig && b.q_orig)                                AS q_orig,
        (a.q_int  && b.q_int)                                 AS q_int
    FROM (
        SELECT lexeme, encoded,
               to_tsquery('english', lexeme) AS q_orig,
               to_tsquery('simple',  encoded) AS q_int
        FROM lex_dict ORDER BY ndoc DESC LIMIT 3
    ) a
    CROSS JOIN (
        SELECT lexeme, encoded,
               to_tsquery('english', lexeme) AS q_orig,
               to_tsquery('simple',  encoded) AS q_int
        FROM lex_dict ORDER BY ndoc DESC OFFSET 3 LIMIT 3
    ) b
    LIMIT 3
)
SELECT
    q_str,
    (SELECT count(*) FROM docs WHERE tsv     @@ q_orig) AS n_orig,
    (SELECT count(*) FROM docs WHERE tsv_int @@ q_int)  AS n_int
FROM pairs;
-- Expected: n_orig = n_int for every row

\echo 'If all counts above are 0 / true, verification passed.'
\echo '05_verify.sql: done'
