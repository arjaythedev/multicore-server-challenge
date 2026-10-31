#!/usr/bin/env bash
# Where does Postgres spend its time? Runs one probe with pg_stat_statements loaded and prints the cost per statement
# over the measured window. Local profiling only: the module is passed at startup, nothing is written to the config,
# Postgres goes back to normal afterwards, and the submission itself never uses it (rule 3).
#   dev/tools.sh dev/profile.sh [think-scale, default 0.25: 20,000 connections sending the load of 80,000 users]
set -euo pipefail
. "$(dirname "$0")/env.sh"
SCALE="${1:-0.25}"
OUT="$DEV_DIR/results/profile-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

restart() { # extra postgres options
  pg_ctl -D "$PGDATA" -m fast -w stop </dev/null >/dev/null 2>&1 || true
  taskset -c "$TARGET_CPUS" pg_ctl -D "$PGDATA" -l "$BENCH_HOME/postgres.log" -o "$1" -w start </dev/null >/dev/null 2>&1
}
trap 'restart ""' EXIT
restart "-c shared_preload_libraries=pg_stat_statements -c pg_stat_statements.max=500 -c pg_stat_statements.track=top"
# The extension lives in the postgres database only; benchmark databases stay untouched.
psql -X -q -d postgres -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements"

LABEL=profile THINK_SCALE="$SCALE" bash "$DEV_DIR/bench.sh" probe 20000 > "$OUT/bench.log" 2>&1 &
bench=$!
# bench.sh warms up first (30 s ramp + 60 s + 15 s tail + 30 s pause), then ramps for 60 s; wait for the measured window.
until compgen -G "$DEV_DIR/results/*-profile/warmup-1000/merged.json" >/dev/null && \
      [ "$(ls -td "$DEV_DIR"/results/*-profile | head -1)" -nt "$OUT" ]; do
  kill -0 "$bench" 2>/dev/null || { echo "bench ended early:"; cat "$OUT/bench.log"; exit 1; }
  sleep 1
done
sleep $(( 30 + 62 ))
psql -X -q -d postgres -c "SELECT pg_stat_statements_reset()" >/dev/null
started=$(date +%s.%N)
sleep 60
elapsed=$(awk "BEGIN{print $(date +%s.%N) - $started}")
psql -X -d postgres --csv > "$OUT/statements.csv" <<'SQL'
SELECT calls, round(total_exec_time::numeric, 0) AS exec_ms, round(mean_exec_time::numeric, 3) AS mean_ms,
       round(max_exec_time::numeric, 1) AS max_ms, plans, rows, shared_blks_hit, shared_blks_read, wal_bytes,
       regexp_replace(query, '\s+', ' ', 'g') AS query
  FROM pg_stat_statements s JOIN pg_database d ON d.oid = s.dbid
 WHERE d.datname LIKE 'bench_%' AND calls > 0
 ORDER BY total_exec_time DESC
SQL
wait "$bench"
cat "$OUT/bench.log" | command grep -E 'users=|failed|died' || true
echo "measured ${elapsed}s, statements in $OUT/statements.csv"
