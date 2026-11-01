#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT.
# Optional: DOMAINS (event loops, default nproc), PG_CONNS_PER_DOMAIN.
set -euo pipefail
exec "$(cd "$(dirname "$0")" && pwd)/bin/conduit"
