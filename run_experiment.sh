#!/usr/bin/env bash
# run_experiment.sh
#
# Full orchestrator for the FTS uid benchmark experiment.
#
# What it does:
#   1. Creates database fts_bench (drops if exists when --clean given)
#   2. Fixes DB-level settings (autovacuum off, JIT off)
#   3. Runs 00_setup.sql -> corpus load -> 02..05 SQL pipeline
#   4. Measures @@ search and ts_rank/ts_rank_cd performance (5 warm runs each)
#   5. Optionally drops OS page cache for cold-cache runs (requires sudo)
#   6. Writes timing results into bench_results table + results/summary.txt
#
# Usage:
#   ./run_experiment.sh [options]
#
# Options:
#   --clean          Drop and recreate fts_bench before starting
#   --docs N         Number of documents to generate (default: 500000)
#   --bench-runs N   Measurement repetitions per query (default: 5)
#   --cold           Drop OS page cache before cold-cache runs (needs sudo)
#   --pguser USER    PostgreSQL superuser (default: postgres)
#   --skip-corpus    Skip corpus generation (reuse existing data)
#   --skip-encode    Skip steps 03+04 (reuse existing tsv_int)
#   --only-bench     Jump straight to benchmarks (all data must exist)
#   -h, --help       Show this help

set -euo pipefail

PGUSER="postgres"
DBNAME="fts_bench"
DOCS=500000
BENCH_RUNS=5
CLEAN=false
COLD=false
SKIP_CORPUS=false
SKIP_ENCODE=false
ONLY_BENCH=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_DIR="${SCRIPT_DIR}/sql"
RESULTS_DIR="${SCRIPT_DIR}/results"
mkdir -p "${RESULTS_DIR}"
LOG="${RESULTS_DIR}/experiment_$(date +%Y%m%d_%H%M%S).log"

# ── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case $1 in
        --clean)       CLEAN=true        ;;
        --docs)        DOCS="$2"; shift  ;;
        --bench-runs)  BENCH_RUNS="$2"; shift ;;
        --cold)        COLD=true         ;;
        --pguser)      PGUSER="$2"; shift ;;
        --skip-corpus) SKIP_CORPUS=true  ;;
        --skip-encode) SKIP_ENCODE=true  ;;
        --only-bench)  ONLY_BENCH=true   ;;
        -h|--help)
            sed -n '2,40p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

# ── Helpers ───────────────────────────────────────────────────────────────────
PG="psql -U ${PGUSER} -d ${DBNAME} -v ON_ERROR_STOP=1"
PG_ADMIN="psql -U ${PGUSER} -d postgres -v ON_ERROR_STOP=1"

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "${LOG}"; }

run_sql_file() {
    local file="$1"
    log "Running $file ..."
    local start=$SECONDS
    ${PG} -f "${SQL_DIR}/${file}" 2>&1 | tee -a "${LOG}"
    log "  -> done in $((SECONDS - start))s"
}

# Execute SQL and return first column of first row
query_scalar() {
    ${PG} -At -c "$1" 2>/dev/null
}

# Execute EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) and print a CSV line:
#   phase,qtype,run,exec_ms,hit_blocks,read_blocks
# Uses a temp file so JSON is never embedded in a bash heredoc (avoids $ expansion).
bench_one() {
    local phase="$1"
    local qtype="$2"
    local sql="$3"    # the SELECT to EXPLAIN
    local run="$4"

    local tmpjson
    tmpjson=$(mktemp /tmp/fts_bench_XXXXXX.json)

    ${PG} -At -c "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ${sql}" > "${tmpjson}" 2>/dev/null

    # Quoted heredoc: bash does NOT expand variables inside <<'PYEOF', so
    # we pass all dynamic values as command-line arguments to Python.
    python3 - "${tmpjson}" "${phase}" "${qtype}" "${run}" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    content = f.read().strip()
if not content:
    sys.stderr.write(f"bench_one: empty EXPLAIN output for phase={sys.argv[2]}\n")
    sys.exit(1)
plan = json.loads(content)
p        = plan[0]["Plan"]
exec_ms  = plan[0].get("Execution Time", 0)
hits     = p.get("Shared Hit Blocks", 0)
reads    = p.get("Shared Read Blocks", 0)
print(f"{sys.argv[2]},{sys.argv[3]},{sys.argv[4]},{exec_ms},{hits},{reads}")
PYEOF
    local rc=$?
    rm -f "${tmpjson}"
    return ${rc}
}

# ── Step 0: Database setup ────────────────────────────────────────────────────
if [[ "${ONLY_BENCH}" == "false" ]]; then
    mkdir -p "${RESULTS_DIR}"
    log "=== FTS uid experiment ==="
    log "docs=${DOCS}, bench_runs=${BENCH_RUNS}, cold=${COLD}"

    if [[ "${CLEAN}" == "true" ]]; then
        log "Dropping existing database ${DBNAME}..."
        ${PG_ADMIN} -c "DROP DATABASE IF EXISTS ${DBNAME};" 2>&1 | tee -a "${LOG}"
    fi

    # Create DB if it doesn't exist
    if ! ${PG_ADMIN} -lqt 2>/dev/null | cut -d\| -f1 | grep -qw "${DBNAME}"; then
        log "Creating database ${DBNAME}..."
        ${PG_ADMIN} -c "CREATE DATABASE ${DBNAME} ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0;" \
            2>&1 | tee -a "${LOG}"
    fi

    # DB-level GUC overrides (survive reconnect)
    log "Configuring database-level GUCs..."
    ${PG} -c "ALTER DATABASE ${DBNAME} SET jit = off;" 2>&1 | tee -a "${LOG}"
    ${PG} -c "ALTER DATABASE ${DBNAME} SET max_parallel_workers_per_gather = 0;" 2>&1 | tee -a "${LOG}"

    # autovacuum is disabled per-table in 00_setup.sql

    run_sql_file "00_setup.sql"
fi

# ── Step 1: Load corpus ───────────────────────────────────────────────────────
if [[ "${ONLY_BENCH}" == "false" && "${SKIP_CORPUS}" == "false" ]]; then
    log "Generating and loading corpus (${DOCS} documents)..."
    local_start=$SECONDS
    python3 "${SCRIPT_DIR}/gen_corpus.py" --docs "${DOCS}" \
        2> >(tee -a "${LOG}" >&2) \
        | ${PG} -c "COPY docs(body) FROM STDIN" 2>&1 | tee -a "${LOG}"
    log "  -> corpus loaded in $((SECONDS - local_start))s"

    ${PG} -c "ANALYZE docs;" 2>&1 | tee -a "${LOG}"
fi

# ── Step 2: Baseline tsvector ─────────────────────────────────────────────────
if [[ "${ONLY_BENCH}" == "false" && "${SKIP_CORPUS}" == "false" ]]; then
    run_sql_file "02_baseline.sql"
fi

# ── Steps 3-4: Dictionary + int-proxy ────────────────────────────────────────
if [[ "${ONLY_BENCH}" == "false" && "${SKIP_ENCODE}" == "false" ]]; then
    run_sql_file "03_dict.sql"
    run_sql_file "04_encode.sql"
fi

# ── Step 5: Verify ────────────────────────────────────────────────────────────
if [[ "${ONLY_BENCH}" == "false" ]]; then
    run_sql_file "05_verify.sql"
fi

# ── Step 6: Build query workload ──────────────────────────────────────────────
log "Building query workload..."
${PG} -c "
    DO \$\$ BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_tables WHERE tablename = 'bench_queries') THEN
            RAISE EXCEPTION 'bench_queries table not found; run 06_bench_search.sql first';
        END IF;
    END\$\$;
" 2>/dev/null || ${PG} -f "${SQL_DIR}/06_bench_search.sql" 2>&1 | tee -a "${LOG}"

# ── Step 7: Measurement loop ──────────────────────────────────────────────────
log "=== Benchmark measurement loop (${BENCH_RUNS} runs each) ==="

RESULTS_CSV="${RESULTS_DIR}/timings_$(date +%Y%m%d_%H%M%S).csv"
echo "phase,qtype,run,exec_ms,hit_blocks,read_blocks" > "${RESULTS_CSV}"

# Helper: run one @@ search benchmark and append to CSV.
# Uses a subquery to pull the tsquery from bench_queries — no shell-level
# string escaping of tsquery literals needed.
measure_search() {
    local phase="$1"    # e.g. search_gin_baseline
    local col="$2"      # tsv or tsv_int
    local qcol="$3"     # q_orig or q_int
    local qtype="$4"    # single | and2 | phrase

    # Verify at least one query of this type exists
    local cnt
    cnt=$(query_scalar "SELECT count(*) FROM bench_queries WHERE qtype = '${qtype}'")
    [[ "${cnt:-0}" -eq 0 ]] && { log "  No ${qtype} query found, skipping"; return; }

    local sql="SELECT count(*) FROM docs
               WHERE ${col} @@ (SELECT ${qcol} FROM bench_queries WHERE qtype = '${qtype}' ORDER BY qid LIMIT 1)"

    for run in $(seq 1 "${BENCH_RUNS}"); do
        local row
        if row=$(bench_one "${phase}" "${qtype}" "${sql}" "${run}"); then
            echo "${row}" >> "${RESULTS_CSV}"
        else
            log "  WARNING: bench_one failed for ${phase}/${qtype} run ${run}"
        fi
    done
    log "  ${phase}/${qtype}: done"
}

# Helper: run one ranking benchmark
measure_rank() {
    local phase="$1"
    local col="$2"
    local qcol="$3"
    local fn="$4"       # ts_rank or ts_rank_cd
    local qtype="$5"

    local cnt
    cnt=$(query_scalar "SELECT count(*) FROM bench_queries WHERE qtype = '${qtype}'")
    [[ "${cnt:-0}" -eq 0 ]] && return

    local sql="SELECT sum(${fn}(${col},
                   (SELECT ${qcol} FROM bench_queries WHERE qtype = '${qtype}' ORDER BY qid LIMIT 1)))
               FROM docs TABLESAMPLE SYSTEM(2) REPEATABLE(42)"

    for run in $(seq 1 "${BENCH_RUNS}"); do
        local row
        if row=$(bench_one "${phase}" "${qtype}" "${sql}" "${run}"); then
            echo "${row}" >> "${RESULTS_CSV}"
        else
            log "  WARNING: bench_one failed for ${phase}/${qtype} run ${run}"
        fi
    done
    log "  ${phase}/${qtype}: done"
}

# ── GIN warm-cache search (GIST dropped so planner is forced to GIN) ─────────
log "--- GIN search (warm cache, GIST indexes dropped to force GIN) ---"
${PG} -c "DROP INDEX IF EXISTS docs_tsv_gist; DROP INDEX IF EXISTS docs_tsvint_gist;" \
    2>&1 | tee -a "${LOG}"

for qt in single and2 phrase; do
    measure_search "search_gin_baseline" "tsv"     "q_orig" "${qt}"
    measure_search "search_gin_int"      "tsv_int" "q_int"  "${qt}"
done

${PG} -c "CREATE INDEX IF NOT EXISTS docs_tsv_gist    ON docs USING GIST(tsv);
          CREATE INDEX IF NOT EXISTS docs_tsvint_gist ON docs USING GIST(tsv_int);" \
    2>&1 | tee -a "${LOG}"

# ── GIST search (GIN dropped so planner is forced to GIST) ───────────────────
log "--- GIST search (warm cache, GIN indexes dropped to force GIST) ---"
${PG} -c "DROP INDEX IF EXISTS docs_tsv_gin; DROP INDEX IF EXISTS docs_tsvint_gin;" \
    2>&1 | tee -a "${LOG}"

for qt in single and2 phrase; do
    measure_search "search_gist_baseline" "tsv"     "q_orig" "${qt}"
    measure_search "search_gist_int"      "tsv_int" "q_int"  "${qt}"
done

${PG} -c "CREATE INDEX IF NOT EXISTS docs_tsv_gin    ON docs USING GIN(tsv);
          CREATE INDEX IF NOT EXISTS docs_tsvint_gin ON docs USING GIN(tsv_int);" \
    2>&1 | tee -a "${LOG}"

# ── Ranking throughput ────────────────────────────────────────────────────────
log "--- Ranking throughput (TABLESAMPLE 2%, warm cache) ---"
for qt in single and2; do
    measure_rank "rank_ts_rank_baseline"    "tsv"     "q_orig" "ts_rank"    "${qt}"
    measure_rank "rank_ts_rank_int"         "tsv_int" "q_int"  "ts_rank"    "${qt}"
    measure_rank "rank_ts_rank_cd_baseline" "tsv"     "q_orig" "ts_rank_cd" "${qt}"
    measure_rank "rank_ts_rank_cd_int"      "tsv_int" "q_int"  "ts_rank_cd" "${qt}"
done

# ── Cold-cache runs (optional, needs sudo) ────────────────────────────────────
if [[ "${COLD}" == "true" ]]; then
    log "--- Cold-cache runs ---"
    log "Flushing OS page cache..."
    sync
    if sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null; then
        log "  Page cache dropped."
    else
        log "  WARNING: could not drop page cache (no sudo?). Cold runs skipped."
        COLD=false
    fi

    if [[ "${COLD}" == "true" ]]; then
        drop_cache() {
            ${PG} -c "CHECKPOINT;" 2>/dev/null
            sync
            sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
        }

        # GIN cold (GIST dropped)
        log "--- GIN search (cold cache) ---"
        ${PG} -c "DROP INDEX IF EXISTS docs_tsv_gist; DROP INDEX IF EXISTS docs_tsvint_gist;" \
            2>&1 | tee -a "${LOG}"
        for qt in single and2; do
            drop_cache
            measure_search "search_gin_baseline_cold" "tsv"     "q_orig" "${qt}"
            drop_cache
            measure_search "search_gin_int_cold"      "tsv_int" "q_int"  "${qt}"
        done
        ${PG} -c "CREATE INDEX IF NOT EXISTS docs_tsv_gist    ON docs USING GIST(tsv);
                  CREATE INDEX IF NOT EXISTS docs_tsvint_gist ON docs USING GIST(tsv_int);" \
            2>&1 | tee -a "${LOG}"

        # GIST cold (GIN dropped)
        log "--- GIST search (cold cache) ---"
        ${PG} -c "DROP INDEX IF EXISTS docs_tsv_gin; DROP INDEX IF EXISTS docs_tsvint_gin;" \
            2>&1 | tee -a "${LOG}"
        for qt in single and2; do
            drop_cache
            measure_search "search_gist_baseline_cold" "tsv"     "q_orig" "${qt}"
            drop_cache
            measure_search "search_gist_int_cold"      "tsv_int" "q_int"  "${qt}"
        done
        ${PG} -c "CREATE INDEX IF NOT EXISTS docs_tsv_gin    ON docs USING GIN(tsv);
                  CREATE INDEX IF NOT EXISTS docs_tsvint_gin ON docs USING GIN(tsv_int);" \
            2>&1 | tee -a "${LOG}"

        # Ranking cold (index not used, but drop cache to evict heap/TOAST pages)
        log "--- Ranking throughput (cold cache) ---"
        for qt in single and2; do
            drop_cache
            measure_rank "rank_ts_rank_baseline_cold"    "tsv"     "q_orig" "ts_rank"    "${qt}"
            drop_cache
            measure_rank "rank_ts_rank_int_cold"         "tsv_int" "q_int"  "ts_rank"    "${qt}"
            drop_cache
            measure_rank "rank_ts_rank_cd_baseline_cold" "tsv"     "q_orig" "ts_rank_cd" "${qt}"
            drop_cache
            measure_rank "rank_ts_rank_cd_int_cold"      "tsv_int" "q_int"  "ts_rank_cd" "${qt}"
        done
    fi
fi

# ── Store timing results in DB ────────────────────────────────────────────────
log "Importing timing CSV into bench_results..."
${PG} -c "\copy bench_results(phase, query_type, run_no, exec_ms, hit_blocks, read_blocks)
          FROM '${RESULTS_CSV}' WITH (FORMAT CSV, HEADER true);" \
    2>&1 | tee -a "${LOG}"

# ── Final report ──────────────────────────────────────────────────────────────
log "=== Final report ==="
run_sql_file "08_results.sql"

# Also dump report to text file
${PG} -f "${SQL_DIR}/08_results.sql" > "${RESULTS_DIR}/report_$(date +%Y%m%d_%H%M%S).txt" 2>&1
log "Report written to ${RESULTS_DIR}/"

# ── Compute medians in Python from CSV ───────────────────────────────────────
python3 - "${RESULTS_CSV}" <<'PYEOF'
import sys, csv, statistics
from collections import defaultdict

data = defaultdict(list)
with open(sys.argv[1]) as f:
    for row in csv.DictReader(f):
        key = (row["phase"], row["qtype"])
        data[key].append(float(row["exec_ms"]))

print()
print("=== Timing summary (ms) ===")
print(f"{'phase':<35} {'qtype':<8} {'n':>3} {'median':>8} {'min':>8} {'max':>8}")
print("-" * 75)
for (phase, qtype), vals in sorted(data.items()):
    med = statistics.median(vals)
    print(f"{phase:<35} {qtype:<8} {len(vals):>3} {med:>8.2f} {min(vals):>8.2f} {max(vals):>8.2f}")

# Speedup ratios (baseline_ms / int_ms; > 1 means int-proxy is faster)
sys.stdout.write("\n=== Speedup ratios (baseline_ms / int_ms) ===\n")
pairs = [
    ("search_gin_baseline",          "search_gin_int",          "GIN search (warm)"),
    ("search_gist_baseline",         "search_gist_int",         "GIST search (warm)"),
    ("rank_ts_rank_baseline",        "rank_ts_rank_int",        "ts_rank (warm)"),
    ("rank_ts_rank_cd_baseline",     "rank_ts_rank_cd_int",     "ts_rank_cd (warm)"),
    ("search_gin_baseline_cold",     "search_gin_int_cold",     "GIN search (cold)"),
    ("search_gist_baseline_cold",    "search_gist_int_cold",    "GIST search (cold)"),
    ("rank_ts_rank_baseline_cold",   "rank_ts_rank_int_cold",   "ts_rank (cold)"),
    ("rank_ts_rank_cd_baseline_cold","rank_ts_rank_cd_int_cold","ts_rank_cd (cold)"),
]
for base_phase, int_phase, label in pairs:
    for qt in ["single", "and2", "phrase"]:
        bvals = data.get((base_phase, qt))
        ivals = data.get((int_phase, qt))
        if not bvals or not ivals:
            continue
        try:
            ratio = statistics.median(bvals) / statistics.median(ivals)
            direction = "int-proxy faster" if ratio > 1 else "int-proxy slower"
            sys.stdout.write(f"  {label:22s} {qt:8s}  x{ratio:.2f}  ({direction})\n")
        except Exception as e:
            sys.stdout.write(f"  {label:22s} {qt:8s}  ERROR: {e}\n")
sys.stdout.flush()
PYEOF

log "=== Experiment complete. Results in ${RESULTS_DIR}/ ==="
