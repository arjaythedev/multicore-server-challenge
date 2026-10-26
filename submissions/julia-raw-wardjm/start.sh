#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT (see SPEC.md);
# optional tuning: LOOPS, DB_READ_CONNS, DB_WRITE_CONNS, BCRYPT_THREADS, BCRYPT_NICE, BATCH_MAX, READ_DEPTH, WRITE_DEPTH.
set -euo pipefail
cd "$(dirname "$0")"
JULIA="${JULIA:-/opt/julia-1.13.2/bin/julia}"
[ -x "$JULIA" ] || JULIA=julia
export JULIA_DEPOT_PATH="$PWD/depot:"
LOOPS="${LOOPS:-2}"
BCRYPT_THREADS="${BCRYPT_THREADS:-2}"
export LOOPS BCRYPT_THREADS
exec "$JULIA" --project=. --startup-file=no --history-file=no -O3 \
  --threads=$((1 + LOOPS + BCRYPT_THREADS)),0 --gcthreads=2 \
  -e 'using Conduit; Conduit.main()'
