#!/usr/bin/env bash
# One fixed-load measurement: loadgen at USERS for SECONDS on a fresh copy of TEMPLATE, reporting throughput,
# latency and where the CPU went (our processes vs Postgres backends), per request.
#
#   bash tests/bench/measure.sh USERS [SECONDS] [THINK_SCALE]
#
# Env: TEMPLATE (conduit_seed), PORT (3110), ARTICLES (500000 for the full seed, 10000 for dev), IPS (4: the users
# spread over 127.0.0.1..IPS, as the official run spreads them over 4 IPs; one IP has only ~28k ports), plus any server
# tuning variables (WORKERS, READ_CONNS, ...), which pass through. Run from the repo root of a Linux clone.
# PGSS=1 (needs pg_stat_statements preloaded, local profiling only): Postgres execution time per statement over the
# measured window, next to the Postgres CPU of the same window.
# DB=<name>: measure on that existing database instead of a fresh copy of TEMPLATE (kept afterwards). On a machine
# with too little RAM for the template, a copy and shared_buffers together, a fresh copy per run makes every run
# disk-bound; measuring repeatedly on one prewarmed copy (tests/bench/prewarm.sh) keeps runs comparable.
# Compare variants in ABBA order: machine noise drifts, and an A-B-B-A sequence cancels linear drift.
set -euo pipefail
USERS=${1:?usage: measure.sh USERS [SECONDS] [THINK_SCALE]}
SECONDS_MEASURE=${2:-30}
THINK=${3:-1}
TEMPLATE=${TEMPLATE:-conduit_seed}
PORT=${PORT:-3110}
ARTICLES=${ARTICLES:-$([ "$TEMPLATE" = conduit_dev ] && echo 10000 || echo 500000)}
RAMP=15
SUB="$(cd "$(dirname "$0")/../.." && pwd)"
ROOT="$(cd "$SUB/../.." && pwd)"
P="psql -X -q -v ON_ERROR_STOP=1 -d postgres"
OUT=$(mktemp -d)
if [ -n "${DB:-}" ]; then
  KEEP_DB=1
else
  DB=measure_$$
  $P -c "CREATE DATABASE $DB TEMPLATE $TEMPLATE STRATEGY FILE_COPY"
fi
cleanup() {
  [ -n "${SPID:-}" ] && kill "$SPID" 2>/dev/null && wait "$SPID" 2>/dev/null || true
  [ -z "${KEEP_DB:-}" ] && { $P -c "DROP DATABASE IF EXISTS $DB WITH (FORCE)" || true; }
  rm -rf "$OUT"
}
trap cleanup EXIT

DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/$DB JWT_SECRET=dev-secret HOST=0.0.0.0 PORT=$PORT \
  "$SUB/bin/conduit" > "$OUT/server.log" 2>&1 &
SPID=$!
for _ in $(seq 60); do curl -sf -o /dev/null "http://127.0.0.1:$PORT/api/tags" && break; sleep 0.5; done

# CPU ticks (utime + stime, all threads) of our processes and of Postgres's processes.
ticks() {
  local ours=0 pg=0 pid
  for pid in $SPID $(pgrep -P "$SPID"); do
    ours=$((ours + $(awk '{print $14 + $15}' "/proc/$pid/stat" 2>/dev/null || echo 0)))
  done
  for pid in $(pgrep -u postgres postgres); do
    pg=$((pg + $(awk '{print $14 + $15}' "/proc/$pid/stat" 2>/dev/null || echo 0)))
  done
  echo "$ours $pg $(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8}' /proc/stat)"
}

(cd "$ROOT/bench" && go build -o "$OUT/loadgen" ./cmd/loadgen)
TARGETS=$(seq -s, -f "http://127.0.0.%g:$PORT" 1 "${IPS:-4}")
"$OUT/loadgen" run -target "$TARGETS" -users "$USERS" -ramp ${RAMP}s -measure "${SECONDS_MEASURE}s" \
  -tail 3s -secret dev-secret -articles "$ARTICLES" -think-scale "$THINK" -run-id "m$$" -out "$OUT/lg.json" \
  > "$OUT/lg.txt" 2>&1 &
LG=$!
sleep $RAMP
[ -n "${PGSS:-}" ] && psql -X -q -d "$DB" -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements; SELECT pg_stat_statements_reset()" > /dev/null
read -r o0 p0 t0 < <(ticks)
sleep "$SECONDS_MEASURE"
read -r o1 p1 t1 < <(ticks)
if [ -n "${PGSS:-}" ]; then
  echo "postgres CPU in the window: $(( (p1 - p0) / $(getconf CLK_TCK) )) s"
  psql -X -d "$DB" -c "
    SELECT round((total_exec_time/1000)::numeric,1) AS exec_s, calls, round((total_exec_time/greatest(calls,1)*1000)::numeric) AS us_call,
           round((rows::numeric/greatest(calls,1)),1) AS rows_call, left(regexp_replace(query,'\s+',' ','g'),70) AS query
    FROM pg_stat_statements WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
    ORDER BY total_exec_time DESC LIMIT 20"
  psql -X -At -d "$DB" -c "SELECT 'total exec s: ' || round((sum(total_exec_time)/1000)::numeric,1) FROM pg_stat_statements WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())"
fi
wait $LG || true

HZ=$(getconf CLK_TCK)
CPUS=$(nproc)
awk -v o=$((o1 - o0)) -v p=$((p1 - p0)) -v t=$((t1 - t0)) -v hz="$HZ" -v s="$SECONDS_MEASURE" -v cpus="$CPUS" '
  $1 == "ALL" { rps = $3; p95 = $6; p99 = $7; err = $9 }
  END {
    printf "req/s %.0f  p95 %s ms  p99 %s ms  err %s%%\n", rps, p95, p99, err
    printf "CPU of the machine: ours %.1f%%  postgres %.1f%%  (of %d CPUs)\n", 100*o/t, 100*p/t, cpus
    if (rps > 0) printf "per request: ours %.1f us  postgres %.1f us\n", o/hz/s/rps*1e6, p/hz/s/rps*1e6
  }' "$OUT/lg.txt"
grep -E "^verdict|^errors" "$OUT/lg.txt" || true
[ -n "${TABLE:-}" ] && grep -E "^(endpoint|GET|POST|PUT|DELETE|ALL)" "$OUT/lg.txt"
kill -0 "$SPID" 2>/dev/null || { echo "SERVER DIED"; tail -20 "$OUT/server.log"; }
