#!/usr/bin/env bash
# Runs a submission on the simulated box: fresh DB copy, build.sh, then start.sh pinned to the box CPUs inside a
# user systemd scope with a memory cap (box = 16 GB shared with Postgres, whose container is capped at 10 GB).
#   app.sh build <submission-dir>
#   app.sh start <submission-dir> [template]   # template: conduit_seed (default) | conduit_dev
#   app.sh stop
#   app.sh conformance                          # against the running app
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BOX_CPUS="${BOX_CPUS:-0-7}"
APP_MEM="${APP_MEM:-6G}"
PORT="${PORT:-3000}"
DB="${RUN_DB:-conduit_run}"
export JWT_SECRET="${JWT_SECRET:-multicore-server-challenge}"
export PATH="$HERE/go/bin:$PATH"
psqlx() { "$HERE/box-pg.sh" psql -X -q -v ON_ERROR_STOP=1 -d postgres "$@"; }
case "${1:-}" in
build)
  DIR="$(cd "$2" && pwd)"; (cd "$DIR" && taskset -c "$BOX_CPUS" bash build.sh) ;;
start)
  DIR="$(cd "$2" && pwd)"; TEMPLATE="${3:-conduit_seed}"
  systemctl --user stop mcsc-app.scope 2>/dev/null || true
  psqlx -c "DROP DATABASE IF EXISTS $DB WITH (FORCE)" -c "CREATE DATABASE $DB TEMPLATE $TEMPLATE STRATEGY FILE_COPY"
  export DATABASE_URL="postgres://conduit:conduit@127.0.0.1:55432/$DB" HOST=0.0.0.0 PORT
  cd "$DIR"
  setsid systemd-run --user --scope --unit=mcsc-app -p MemoryMax="$APP_MEM" -p MemorySwapMax=0 \
    taskset -c "$BOX_CPUS" bash start.sh > "$HERE/app.log" 2>&1 < /dev/null &
  for _ in $(seq 60); do curl -sf -o /dev/null "http://127.0.0.1:$PORT/api/tags" && break; sleep 1; done
  curl -sf -o /dev/null "http://127.0.0.1:$PORT/api/tags" && echo "app up on :$PORT (db $DB from $TEMPLATE)" \
    || { echo "GET /api/tags not 200 after 60 s"; tail -30 "$HERE/app.log"; exit 1; } ;;
stop) systemctl --user stop mcsc-app.scope 2>/dev/null || true ;;
conformance) "$HERE/bin/conformance" -base "http://127.0.0.1:$PORT" -secret "$JWT_SECRET" -q ;;
*) echo "usage: $0 build|start|stop|conformance"; exit 2 ;;
esac
