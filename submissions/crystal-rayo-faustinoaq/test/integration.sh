#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PGHOST=127.0.0.1 PGUSER=postgres PGPASSWORD=postgres
db="rayo_mc_wave3_$$"
pid=""
cleanup() {
  if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  psql -Xq -d postgres -c "DROP DATABASE IF EXISTS $db WITH (FORCE)"
}
trap cleanup EXIT
psql -Xq -v ON_ERROR_STOP=1 -d postgres -c "CREATE DATABASE $db TEMPLATE conduit_dev STRATEGY FILE_COPY"
export DATABASE_URL="postgres://conduit:conduit@127.0.0.1:5432/$db"
export JWT_SECRET=multicore-server-challenge WORKERS=3 HOST=127.0.0.1 PORT=3391
bash start.sh > bin/integration-server.log 2>&1 &
pid=$!
for _ in $(seq 60); do curl -sf -o /dev/null "http://$HOST:$PORT/api/tags" && break; sleep 1; done
curl -sf -o /dev/null "http://$HOST:$PORT/api/tags"
python3 test/bcrypt_fallback.py "http://$HOST:$PORT"
python3 test/concurrency.py "http://$HOST:$PORT"
python3 test/batch_reads.py "http://$HOST:$PORT"
