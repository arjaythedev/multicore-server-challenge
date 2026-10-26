#!/usr/bin/env bash
# Runs the server in the foreground. HOST/PORT and DATABASE_URL come from the
# challenge environment. WORKERS defaults to one process per vCPU; every
# process binds with SO_REUSEPORT and owns one PostgreSQL connection.
# Four processes per vCPU gives PostgreSQL enough independent blocking queries
# without approaching the 95-connection application limit.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$DIR/bin/conduit"
WORKERS="${WORKERS:-$(( $(nproc 2>/dev/null || echo 1) * 4 ))}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-80}"
export HOST PORT
pids=()
cleanup() {
  trap - TERM INT EXIT
  for pid in "${pids[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  for pid in "${pids[@]:-}"; do wait "$pid" 2>/dev/null || true; done
}
trap cleanup TERM INT EXIT
for _ in $(seq 1 "$WORKERS"); do
  "$BIN" &
  pids+=("$!")
done
wait -n || true
cleanup
