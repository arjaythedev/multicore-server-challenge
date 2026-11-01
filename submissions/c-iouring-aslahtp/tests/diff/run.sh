#!/usr/bin/env bash
# Differential test against the Go reference server (examples/go).
#
#   bash tests/diff/run.sh [TEMPLATE] [extra diffcheck flags...]
#
# TEMPLATE is the seed database to copy (conduit_dev by default; conduit_seed for the full seed). Reads run with
# both servers on one copy; the write scenarios then run with each server on its own fresh copy. Needs the
# repo's examples/go, Go, psql (superuser via the usual PG* variables) and curl. Run from anywhere.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUB="$(cd "$HERE/../.." && pwd)"
ROOT="$(cd "$SUB/../.." && pwd)"
TEMPLATE="${1:-conduit_dev}"
shift || true
PSQL="psql -X -q -v ON_ERROR_STOP=1 -d postgres"
SECRET=multicore-server-challenge
TMP="$(mktemp -d)"
PIDS=()
DBS=()

cleanup() {
  for p in "${PIDS[@]}"; do pkill -P "$p" 2>/dev/null || true; kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
  for d in "${DBS[@]}"; do $PSQL -c "DROP DATABASE IF EXISTS $d WITH (FORCE)" || true; done
  rm -rf "$TMP"
}
trap cleanup EXIT

newdb() {
  local d="diff_$$_$1"
  $PSQL -c "CREATE DATABASE $d TEMPLATE $TEMPLATE STRATEGY FILE_COPY"
  DBS+=("$d")
  echo "$d"
}

start() {  # name, dir, port, db
  DATABASE_URL="postgres://conduit:conduit@127.0.0.1:5432/$4" JWT_SECRET=$SECRET HOST=127.0.0.1 PORT=$3 \
    DB_POOL_SIZE=16 bash "$2/start.sh" > "$TMP/$1.log" 2>&1 &
  PIDS+=($!)
  for _ in $(seq 60); do curl -sf -o /dev/null "http://127.0.0.1:$3/api/tags" && return; sleep 0.5; done
  echo "$1 did not start"; cat "$TMP/$1.log"; exit 1
}

stop_all() {
  for p in "${PIDS[@]}"; do pkill -P "$p" 2>/dev/null || true; kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
  PIDS=()
}

echo "== build"
bash "$ROOT/examples/go/build.sh" > /dev/null
bash "$SUB/build.sh" > /dev/null
(cd "$HERE" && go build -o "$TMP/diffcheck" .)

echo "== reads ($TEMPLATE, one shared copy)"
db=$(newdb r)
start ref "$ROOT/examples/go" 3001 "$db"
start sub "$SUB" 3002 "$db"
rc=0
"$TMP/diffcheck" -a http://127.0.0.1:3001 -b http://127.0.0.1:3002 -secret $SECRET "$@" || rc=1
stop_all

echo "== writes (a copy each)"
dba=$(newdb wa)
dbb=$(newdb wb)
start ref "$ROOT/examples/go" 3001 "$dba"
start sub "$SUB" 3002 "$dbb"
"$TMP/diffcheck" -a http://127.0.0.1:3001 -b http://127.0.0.1:3002 -secret $SECRET -n 0 -writes 20 -run w || rc=1
if [ $rc != 0 ]; then echo "== server log (last 20 lines)"; tail -20 "$TMP/sub.log"; fi
exit $rc
