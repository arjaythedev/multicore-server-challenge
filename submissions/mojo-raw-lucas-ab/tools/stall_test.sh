#!/usr/bin/env bash
# Write-stall isolation test: while loadgen runs, a psql session repeatedly holds `LOCK TABLE favorites IN EXCLUSIVE
# MODE` (blocks favorite/unfavorite writes, still allows reads) for STALL seconds every EVERY seconds. A server that
# keeps reads apart from writes should show stalled writes only; one that queues reads behind writes on shared
# connections shows reads stalling too. Runs the given server binary natively on a fresh copy of conduit_dev.
# FOR LOCAL TESTING ONLY.
#
#   bash tools/stall_test.sh <label> <server binary> [users] [measure seconds] [stall seconds] [every seconds]
#
# Output: /tmp/stall/<label>.loadgen (per-endpoint latency) and a short read/write summary.
set -euo pipefail
LABEL=$1 BIN=$2 USERS=${3:-15000} MEASURE=${4:-60} STALL=${5:-3} EVERY=${6:-10}
PORT=3400
DB="stall_$LABEL"
mkdir -p /tmp/stall
ulimit -n 200000
export PGDATABASE=postgres
pkill -x conduit 2>/dev/null || true
sleep 1
psql -X -q -c "DROP DATABASE IF EXISTS $DB WITH (FORCE)" -c "CREATE DATABASE $DB TEMPLATE conduit_dev STRATEGY FILE_COPY" \
  2>&1 | grep -vE "NOTICE|NOTA" || true
DATABASE_URL="postgres://conduit:conduit@127.0.0.1:5432/$DB" JWT_SECRET=dev-secret HOST=127.0.0.1 PORT=$PORT \
  "$BIN" > "/tmp/stall/$LABEL.server" 2>&1 &
for _ in $(seq 50); do curl -sf -o /dev/null "http://127.0.0.1:$PORT/api/tags" && break; sleep 0.2; done

# The lock loop starts after the ramp and runs through the measured window.
(
  sleep 12
  end=$(( $(date +%s) + MEASURE ))
  while [ "$(date +%s)" -lt "$end" ]; do
    psql -X -q -d "$DB" -c "BEGIN; LOCK TABLE favorites IN EXCLUSIVE MODE; SELECT pg_sleep($STALL); COMMIT;" >/dev/null 2>&1 || true
    sleep $(( EVERY - STALL ))
  done
) &
LOCKER=$!
/tmp/loadgen run -target "http://127.0.0.1:$PORT" -users "$USERS" -ramp 10s -measure "${MEASURE}s" -tail 5s \
  -secret dev-secret -articles 10000 -run-id "stall$LABEL$$" -out "/tmp/stall/$LABEL.json" > "/tmp/stall/$LABEL.loadgen" 2>&1 || true
kill $LOCKER 2>/dev/null || true
wait $LOCKER 2>/dev/null || true
pkill -x conduit 2>/dev/null || true
psql -X -q -c "DROP DATABASE IF EXISTS $DB WITH (FORCE)" 2>&1 | grep -vE "NOTICE|NOTA" || true
echo "== $LABEL ($STALL s write stall every $EVERY s)"
grep -E "^endpoint|^GET /api/tags |^GET /api/articles/:slug |^GET /api/articles |^GET /api/articles/feed|^POST /api/articles/:slug/favorite|^POST /api/articles/:slug/comments|^ALL" \
  "/tmp/stall/$LABEL.loadgen"
