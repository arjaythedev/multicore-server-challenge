#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT (see static_config.yaml).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
CORES="$(nproc)"
# HTTP/coroutine workers: one per core. bcrypt gets its own pool of half the cores.
export WORKER_THREADS="${WORKER_THREADS:-$CORES}"
export BCRYPT_THREADS="${BCRYPT_THREADS:-$(( CORES > 1 ? CORES / 2 : 1 ))}"
# Postgres allows 100 connections and we may use 95: 48 is plenty for 8 cores of Postgres.
export DB_POOL_SIZE="${DB_POOL_SIZE:-48}"
export HOST="${HOST:-127.0.0.1}" PORT="${PORT:-3000}"
# Session setting on our own connections (libpq reads PGOPTIONS; it survives userver's DISCARD ALL): no JIT.
# Web queries are short, and a misestimated plan would otherwise spend milliseconds compiling on every call.
export PGOPTIONS="${PGOPTIONS:+$PGOPTIONS }-c jit=off"
exec "$DIR/build/conduit" --config "$DIR/static_config.yaml"
