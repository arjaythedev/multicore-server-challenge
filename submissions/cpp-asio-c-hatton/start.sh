#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT.
# Tuning knobs (defaults in parentheses): THREADS (cores), PG_READ_CONNS (1 per thread), PG_WRITE_CONNS (1 per
# thread), BCRYPT_THREADS (cores).
set -euo pipefail
exec "$(cd "$(dirname "$0")" && pwd)/bin/conduit"
