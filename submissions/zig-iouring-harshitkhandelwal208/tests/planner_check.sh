#!/usr/bin/env bash
# Differential check of the batch planner. Three servers on the same copy of the seed:
#   reference  one statement per request (BATCH_MAX=1, planner off)           port 3101
#   planner    the defaults (planner on, 100 ms window)                       port 3102
#   failing    the defaults with TEST_FAIL_BATCHES=1: every plan fails once   port 3103
# batchdiff.py fires concurrent reads at a server and compares every response byte for byte with the reference, both on
# spread-out and on hot (duplicate-heavy) requests. The failing server must also log planned batches that failed.
#
#   usage: tests/planner_check.sh [submission directory]      (default: the directory above this script)
# Needs psql (PGHOST / PGPORT / PGUSER as for test/run.sh), python3, and a database $TEMPLATE (default conduit_seed;
# seed/make-seed.sh builds it). Creates and drops its own database.
set -euo pipefail
S="$(cd "${1:-$(dirname "$0")/..}" && pwd)"
TEMPLATE="${TEMPLATE:-conduit_seed}"
DB="planner_check_$$"
LOG="$(mktemp -d)"
PSQL="psql -X -q -v ON_ERROR_STOP=1 -d postgres"
case "${PGHOST:-}" in ""|/*) DBHOST=127.0.0.1 ;; *) DBHOST="$PGHOST" ;; esac
export DATABASE_URL="postgres://conduit:conduit@$DBHOST:${PGPORT:-5432}/$DB" JWT_SECRET=multicore-server-challenge HOST=127.0.0.1

PIDS=()
cleanup() {
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  for p in "${PIDS[@]}"; do wait "$p" 2>/dev/null || true; done
  $PSQL -c "DROP DATABASE IF EXISTS $DB WITH (FORCE)" >/dev/null 2>&1 || true
  rm -rf "$LOG"
}
trap cleanup EXIT

$PSQL -c "CREATE DATABASE $DB TEMPLATE $TEMPLATE STRATEGY FILE_COPY"
cd "$S"
[ -x bin/conduit ] || { echo "build first: bash build.sh"; exit 1; }
BATCH_MAX=1 PLAN_MIN=0 READ_WINDOW_US=0 PORT=3101 ./bin/conduit >"$LOG/ref.log" 2>&1 & PIDS+=($!)
PORT=3102 ./bin/conduit >"$LOG/plan.log" 2>&1 & PIDS+=($!)
TEST_FAIL_BATCHES=1 PORT=3103 ./bin/conduit >"$LOG/fail.log" 2>&1 & PIDS+=($!)
for port in 3101 3102 3103; do
  up=0
  for _ in $(seq 120); do
    if curl -sf -o /dev/null "http://127.0.0.1:$port/api/tags"; then up=1; break; fi
    sleep 0.5
  done
  [ "$up" = 1 ] || { echo "server on $port did not start"; cat "$LOG"/*.log; exit 1; }
done

for hot in 0 1; do
  echo "== planner defaults, HOT=$hot"
  HOT=$hot python3 tests/batchdiff.py 3101 3102
done
for hot in 0 1; do
  echo "== planner with forced failures, HOT=$hot"
  HOT=$hot python3 tests/batchdiff.py 3101 3103
done
failed=$(grep -c 'planned batch failed' "$LOG/fail.log" || true)
echo "planned batches that failed and were retried: $failed"
[ "$failed" -gt 0 ] || { echo "the failure hook never fired: the planner's failure path was not exercised"; exit 1; }
echo "PASS"
