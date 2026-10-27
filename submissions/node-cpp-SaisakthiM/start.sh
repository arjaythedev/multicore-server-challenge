#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT.
# Optional tuning: WORKERS (default = cores), READ_CONNS (4) / WRITE_CONNS (2) Postgres connections per worker,
# BCRYPT_THREADS (2) per worker, NODE_WORKER_FLAGS, CONDUIT_STATS=1 (event-loop utilisation every 5 s).
set -euo pipefail
cd "$(dirname "$0")"
NODE="$(command -v node || true)"
[ -n "$NODE" ] || NODE=/usr/local/bin/node
exec "$NODE" src/main.js
