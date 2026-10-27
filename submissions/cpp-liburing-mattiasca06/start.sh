#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT
# (optional tuning: WORKERS, DB_CONNS, BCRYPT_THREADS; see README.md).
set -euo pipefail
exec "$(cd "$(dirname "$0")" && pwd)/bin/conduit"
