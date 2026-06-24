# FTS uid experiment - replacing string tokens with integer identifiers

## Motivation

PostgreSQL FTS stores tokens in the 'tsvector` as string variables. When searching and ranking
documents, the kernel performs a binary search for tokens with byte-by-byte string comparison. Hypothesis:

> If you replace string tokens with fixed 4-byte integer identifiers,
> then the size of the `tsvector` will decrease, the passage through GIN/GIST will accelerate, and - most importantly - they will accelerate
> the `ts_rank` / `ts_rank_cd` functions that do not use the index and run entirely on the CPU.

The real C-extension is not being written yet. Instead, a proxy is made: tokens
are replaced with 4-character strings from the alphabet `0-9a-z` (base36). The key width is the same -
4 bytes - so the proxy is an honest lower threshold for a real int4 extension.

---

## Methodology

### Proxy encoding

Instead of the real `int4`, a string of 4 characters of the alphabet `0-9a-z` is used (36 characters,
36^4 = 1,679,616 unique values). The alphabet is chosen in lowercase because `to_tsquery('simple', ...)`
lowercases tokens - uppercase characters would cause collisions.

Example: the token `"initi"` (the most frequent in the corpus) gets id 1 -> encoded = `"0001"`.

The positions and weights of words in the tsvector are fully preserved, so the proxy vector
is semantically equivalent to the original one: it is checked by a verification step.

### Benchmark parameters

| Parameter | Value |
|---|---|
| PostgreSQL | 14.23 |
| Corpus | 10,000 documents, 50-200 words, synthetic from `/usr/share/dict/words` |
| FTS configuration | `english` (for baseline), `simple` (for proxy requests) |
| JIT | disabled (`SET jit = off`) |
| Concurrency | disabled (`max_parallel_workers_per_gather = 0`) |
| Cache | warm (all in `shared_buffers`) |
| Repetitions | 10 runs per point, median |
| GIN vs GIST | are measured separately: GIST is dropped before GIN measurement, and vice versa |

### Request load

- **single** - 500 queries per term (top 500 in terms of frequency in the corpus)
- **and2** - 200 AND-requests from two terms
- **phrase** - 200 phrase queries (`<->`)

For each text query, its proxy twin is built: tokens are replaced
with encoded IDs, the configuration is changed from `english` to `simple`.

---

## Repository structure

```
FTS_uid_research/
├── gen_corpus.py # case generator (seed=42, reproducible)
├── run_experiment.sh # startup script
└── sql/
├── 00_setup.sql # docs tables + bench_results, GUC commit
    ├── 02_baseline.sql # STORED tsvector-column + GIN + GIST
    ├── 03_dict.sql # encode_id(), decode_id(), lex_dict table
    ├── 04_encode.sql # tsv_to_int(), batch UPDATE + indexes
├── 05_verify.sql # checking the equivalence of search results
    ├── 06_bench_search.sql # bench_queries table + EXPLAIN ANALYZE BUFFERS
    ,── 07_bench_rank.sql # TABLESAMPLE throughput + top-20 scenario
    └── 08_results.sql # sizes + medians
```

---

## Launch

```bash
# Full run (creates fts_bench database, generates 500K documents)
./run_experiment.sh --clean --docs 500000

# Quick test on a small
case./run_experiment.sh --clean --docs 10000

# Measurements only (data has already been uploaded)
./run_experiment.sh --only-bench --bench-runs 10
```

The results are saved in `results/`:
- `timings_YYYYMMDD_HHMMSS.csv` - raw measurements
- `report_YYYYMMDD_HHMMSS.txt ` - text report from `08_results.sql`
- `experiment_YYYYMMDD_HHMMSS.log` - full log

---

## Results (10,000 documents, warm cache)

### Dimensions

| Object | Baseline (lines) | Int Proxy (base36) | Change |
|---|---|---|---|
| tsvector heap column | 18 MB | 14 MB | **-19%** |
| Average tsvector per line | 1,859 bytes | 1,503 bytes | **-19%** |
| GIN index | 7,968 kB | 7,856 kB | -1.4% |
| GIST index | 3,336 kB | 3,360 kB | +0.7% (within noise limits) |

Lexicon size: 25,294 unique tokens (10K documents, `english` configuration).
Maximum encoded id: `0jim` (base 36, 4 characters, range covers 1.67M tokens).

### Search Performance (GIN)

Before the GIN measurement, the GIST indexes were dropped so that the scheduler was guaranteed to use GIN.

| Request type | Baseline, ms | Int proxy, ms | Speedup |
|---|---|---|---|
| single (one term) | 2.59 | 1.93 | **x1.34** |
| and2 (two terms AND) | 0.25 | 0.24 | x1.03 |
| phrase (phrase `<->`) | 0.37 | 0.37 | x1.02 |

### Search Performance (GIST)

| Request type | Baseline, ms | Int proxy, ms | Speedup |
|---|---|---|---|
| single | 9.20 | 9.26 | x0.99 |
| and2 | 2.93 | 3.84 | x0.76 |
| phrase | 2.99 | 3.91 | x0.77 |

### Ranking performance - warm cache (TABLESAMPLE 2%~200 rows)

| Function | Request type | Baseline, ms | Int Proxy, ms | Speedup |
|---|---|---|---|---|
| `ts_rank` | single | 1.44 | 1.19 | **x1.21** |
| `ts_rank` | and2 | 1.53 | 1.22 | **x1.25** |
| `ts_rank_cd` | single | 1.62 | 1.39 | **x1.17** |
| `ts_rank_cd` | and2 | 1.91 | 1.57 | **x1.22** |

---

## Results - cold cache

Before each measurement: `CHECKPOINT` + `sync' + `echo 3 > /proc/sys/vm/drop_caches`.
This resets both the OS page cache and PostgreSQL shared_buffers (after CHECKPOINT, dirty
pages are written to disk and can be evicted by the OS).

### Search performance (GIN, cold cache)

| Request type | Baseline, ms | Int proxy, ms | Speedup |
|---|---|---|---|
| single | 1.95 | 1.96 | x1.00 |
| and2 | 0.23 | 0.30 | x0.75 |

### Search performance (GIST, cold cache)

| Request type | Baseline, ms | Int proxy, ms | Speedup |
|---|---|---|---|
| single | 9.32 | 8.75 | **x1.07** |
| and2 | 3.04 | 3.79 | x0.80 |

### Ranking performance - Cold cache

| Function | Request type | Baseline, ms | Int Proxy, ms | Speedup |
|---|---|---|---|---|
| `ts_rank` | single | 1.60 | 1.22 | **x1.31** |
| `ts_rank` | and2 | 1.63 | 1.36 | **x1.20** |
| `ts_rank_cd` | single | 1.71 | 1.38 | **x1.24** |
| `ts_rank_cd` | and2 | 1.90 | 1.57 | **x1.21** |

### Summary table: warm vs cold

| Metric | Warm | Cold |
|---|---|---|
| GIN single | x0.99 | x1.00 |
| GIST single | x1.00 | **x1.07** |
| ts_rank | x1.21-1.25 | **x1.20-1.31** |
| ts_rank_cd | x1.17-1.22 | **x1.21-1.24** |

---

## Summary results for 500,000 documents (warm + cold cache)
```
=== Speedup ratios (baseline_ms / int_ms) ===
  GIN search (warm)      single    x1.04  (int-proxy faster)
  GIN search (warm)      and2      x0.98  (int-proxy slower)
  GIN search (warm)      phrase    x1.10  (int-proxy faster)
  GIST search (warm)     single    x3.23  (int-proxy faster)
  GIST search (warm)     and2      x0.83  (int-proxy slower)
  GIST search (warm)     phrase    x0.83  (int-proxy slower)
  ts_rank (warm)         single    x1.20  (int-proxy faster)
  ts_rank (warm)         and2      x1.24  (int-proxy faster)
  ts_rank_cd (warm)      single    x1.15  (int-proxy faster)
  ts_rank_cd (warm)      and2      x1.20  (int-proxy faster)
  GIN search (cold)      single    x1.00  (int-proxy faster)
  GIN search (cold)      and2      x1.04  (int-proxy faster)
  GIST search (cold)     single    x0.87  (int-proxy slower)
  GIST search (cold)     and2      x0.91  (int-proxy slower)
  ts_rank (cold)         single    x1.31  (int-proxy faster)
  ts_rank (cold)         and2      x1.44  (int-proxy faster)
  ts_rank_cd (cold)      single    x1.42  (int-proxy faster)
  ts_rank_cd (cold)      and2      x1.08  (int-proxy faster)
```

## Interpretation of results

### Ranking: the hypothesis is confirmed, the effect is stable

`ts_rank` and `ts_rank_cd` are accelerated by **8-44%** with both warm and cold cache.
Acceleration with a cold cache is even slightly higher: a smaller `tsvector` -> fewer pages are read
from disk with TABLESAMPLE scanning + faster CPU comparisons. This is purely a CPU effect,
independent of the I/O - the index ranking function is not used.

### GIN: The difference in noise limits on a 10K enclosure

A one-minute GIN search shows x0.99-1.00 - almost no difference. Reason: GIN
The posting sheets are about the same size (7968 vs 7856 kB, 1.4% difference), and 10K documents
are fully cached. A significant difference was expected for 500K+ documents, it was assumed that the index would not
fit into memory and I/O readings of shorter posting sheets would give a measurable gain, but the result was a small gain: x1.00-1.04 

### GIST: structural slowdown for AND queries

GIST slows down for AND/phrase in both warm (x0.78) and cold (x0.80) mode.
This is not an I/O artifact - the gap is the same for any cache state. Most likely there is a structural reason here:
GIST uses signature hashing of tokens to build a bitmap. Base36 identifiers
like `0001`, `0002`, ... are concentrated at the beginning of the alphabet and are worse distributed in the
hash space than natural English words. This results in a higher number
false-positive when checking the AND-condition and additional heap-fetches for recheck.

### Proxy restriction

The proxy uses base36 strings (4 bytes of content + 1 byte varlena header = 5 bytes)
instead of the real `int4` (4 bytes without header). Also, string comparison is a `memcmp`,
whereas int4 is compared by a single machine instruction. Therefore, if the proxy gives X% acceleration, the real int4-extension will give at least X%.