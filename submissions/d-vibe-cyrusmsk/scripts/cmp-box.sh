#!/usr/bin/env bash
# Compares the Go example vs this D submission inside the Linux test container
# (image vibetest:ready, container name vibetest). Each case runs on a fresh
# copy of the conduit_dev seed and leaves the box clean.
#
#   bash /tmp/cmp.sh <users> [ramp] [measure]
#
# Needs: postgres 18 running, /tmp/loadgen, the go binary at
# /opt/ch/examples/go/bin/conduit, this submission at
# /opt/ch/submissions/d-vibe-cyrusmsk. Full loadgen tables print per case;
# a compact side-by-side summary prints at the end.
set -u
USERS="${1:?usage: bash /tmp/cmp.sh <users> [ramp] [measure]}"
RAMP="${2:-1m}"
MEASURE="${3:-1m}"
export JWT_SECRET=multicore-server-challenge CONDUIT_JWT_SECRET=multicore-server-challenge
export HOST=127.0.0.1 PORT=3000
BASE="http://$HOST:$PORT"
apsql() { su postgres -c "psql -X -q -d postgres -v ON_ERROR_STOP=1 -c \"$1\""; }

wait_up() {
  for _ in $(seq 60); do curl -sf -o /dev/null "$BASE/api/tags" && return 0; sleep 1; done
  echo "SERVER NEVER ANSWERED ($1)"; tail -20 "$2"; return 1
}

run_case() {
  local name="$1"; shift
  local db="cmp_$name"
  echo "===== $name (db $db, users $USERS, ramp $RAMP, measure $MEASURE) ====="
  apsql "DROP DATABASE IF EXISTS $db WITH (FORCE)"
  apsql "CREATE DATABASE $db TEMPLATE conduit_dev STRATEGY FILE_COPY"
  export DATABASE_URL="postgres://conduit:conduit@127.0.0.1:5432/$db"
  "$@" > "/tmp/srv-$name.log" 2>&1 &
  local pid=$!
  wait_up "$name" "/tmp/srv-$name.log" || { kill -9 $pid 2>/dev/null; return 1; }
  /tmp/loadgen run -target "$BASE" -users "$USERS" -articles 10000 -ramp "$RAMP" -measure "$MEASURE" -run-id "${name}-$(date +%s)" -out "/tmp/res-$name.json"
  kill $pid 2>/dev/null; wait $pid 2>/dev/null || true
  for _ in $(seq 30); do curl -sf -o /dev/null "$BASE/api/tags" && sleep 1 || break; done
  apsql "DROP DATABASE IF EXISTS $db WITH (FORCE)"
}

summarize() {
  echo "--- $1 ---"
  /tmp/loadgen merge -o /dev/null "/tmp/res-$1.json" 2>&1 | grep -E '^(ALL|verdict)'
}

run_case go bash /opt/ch/examples/go/start.sh
run_case d  bash /opt/ch/submissions/d-vibe-cyrusmsk/start.sh
echo "===== summary (count, req/s, p50, p90, p95, p99, max, err%) ====="
summarize go
summarize d
echo "===== done ====="
