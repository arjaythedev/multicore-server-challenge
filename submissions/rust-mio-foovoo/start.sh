#!/usr/bin/env bash
# Runs the release binary in the foreground. Required: DATABASE_URL, JWT_SECRET, HOST, PORT.
# Tunables (defaults scale with the CPU count; see README): LOOPS, PG_HEAVY, PG_READ, PG_WRITE, PG_ROUTE, READ_BATCH,
# WRITE_BATCH, BCRYPT_THREADS, BCRYPT_PAIR_WAIT_MS, BCRYPT_NICE, PG_PLAN_CACHE_MODE.
set -euo pipefail
exec "$(cd "$(dirname "$0")" && pwd)/target/release/conduit"
