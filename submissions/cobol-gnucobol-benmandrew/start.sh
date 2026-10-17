#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT (SPEC.md).
# Worker processes for 3/4 of the CPUs this process may run on, each with PG_CONNS pipelined Postgres
# connections.
set -euo pipefail
n=$(nproc)
export WORKERS="${WORKERS:-$(( n * 3 / 4 > 0 ? n * 3 / 4 : 1 ))}"
export PG_CONNS="${PG_CONNS:-2}"
exec "$(cd "$(dirname "$0")" && pwd)/bin/conduit"
