-- 03_dict.sql
-- Builds the lexeme -> integer id dictionary from the baseline tsvector column,
-- then creates the encode_id() helper function.
--
-- encode_id(n):
--   Maps n (1-based) -> exactly 4 characters from alphabet '0-9a-z' (base36).
--   ALL LOWERCASE: critical so that to_tsquery('simple', encoded) does not
--   alter the token (simple config lowercases input; lowercase stays unchanged).
--   Byte-level sort order matches numeric order (digits < lowercase letters in ASCII).
--   4 chars base36 = 36^4 = 1,679,616 distinct lexemes — enough for any real corpus.

\timing on

-- ── Helper functions ───────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION encode_id(n bigint) RETURNS text
LANGUAGE plpgsql IMMUTABLE STRICT
AS $$
DECLARE
    -- All lowercase: '0'<...<'9' < 'a'<...<'z'  (ASCII order preserved)
    -- This guarantees byte-level sort order == numeric order.
    chars CONSTANT text := '0123456789abcdefghijklmnopqrstuvwxyz';
    res   text := '';
    i     int;
BEGIN
    IF n < 0 OR n >= 36::bigint^4 THEN
        RAISE EXCEPTION 'encode_id: value % out of range [0, 36^4)', n;
    END IF;
    FOR i IN 1..4 LOOP
        res := substr(chars, (n % 36)::int + 1, 1) || res;
        n   := n / 36;
    END LOOP;
    RETURN res;
END;
$$;

CREATE OR REPLACE FUNCTION decode_id(s text) RETURNS bigint
LANGUAGE plpgsql IMMUTABLE STRICT
AS $$
DECLARE
    chars CONSTANT text := '0123456789abcdefghijklmnopqrstuvwxyz';
    res   bigint := 0;
    i     int;
    pos   int;
BEGIN
    IF length(s) <> 4 THEN
        RAISE EXCEPTION 'decode_id: expected 4 chars, got %', length(s);
    END IF;
    FOR i IN 1..4 LOOP
        pos := strpos(chars, substr(s, i, 1)) - 1;
        IF pos < 0 THEN
            RAISE EXCEPTION 'decode_id: invalid character ''%'' in ''%''', substr(s,i,1), s;
        END IF;
        res := res * 36 + pos;
    END LOOP;
    RETURN res;
END;
$$;

-- ── Lexeme dictionary ──────────────────────────────────────────────────────────
-- ts_stat scans the entire tsv column and returns (word, ndoc, nentry).
-- We assign ids in descending ndoc order so frequent lexemes get small ids.

\echo 'Building lex_dict via ts_stat (may take a few minutes)...'

DROP TABLE IF EXISTS lex_dict;
CREATE TABLE lex_dict AS
SELECT
    word                                          AS lexeme,
    row_number() OVER (ORDER BY ndoc DESC, word)  AS id,
    ndoc,
    nentry
FROM ts_stat('SELECT tsv FROM docs');

ALTER TABLE lex_dict ADD PRIMARY KEY (id);
CREATE UNIQUE INDEX lex_dict_lexeme_idx ON lex_dict (lexeme);

-- Pre-compute encoded form as a plain column (avoids repeated function calls)
ALTER TABLE lex_dict ADD COLUMN encoded text;
UPDATE lex_dict SET encoded = encode_id(id);
ALTER TABLE lex_dict ALTER COLUMN encoded SET NOT NULL;
CREATE INDEX lex_dict_encoded_idx ON lex_dict (encoded);

ANALYZE lex_dict;

\echo ''
\echo '=== Lexicon statistics ==='
SELECT
    count(*)        AS total_lexemes,
    max(id)         AS max_id,
    encode_id(max(id)) AS max_encoded,
    min(ndoc)       AS min_ndoc,
    round(avg(ndoc))AS avg_ndoc,
    max(ndoc)       AS max_ndoc
FROM lex_dict;

\timing off
\echo '03_dict.sql: done'
