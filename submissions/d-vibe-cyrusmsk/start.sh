#!/usr/bin/env bash
# Runs the server in the foreground. Configured only by the SPEC.md env vars:
# DATABASE_URL, JWT_SECRET, HOST, PORT. Optional: THREADS (event loop threads,
# default: the number of cores) and CONNS (max Postgres connections overall,
# default 95, which is what SPEC.md allows).
set -euo pipefail
cd "$(dirname "$0")"
exec ./bin/conduit-vibed
