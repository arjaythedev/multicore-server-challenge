#!/usr/bin/env bash
# Runs bin/conduit in the FOREGROUND as required by the benchmark's systemd
# unit. All configuration is read from the environment exactly as SPEC.md's
# Runtime Contract specifies and is inherited (forwarded) verbatim:
#
#   DATABASE_URL  postgres://conduit:conduit@127.0.0.1:5432/conduit
#   JWT_SECRET    multicore-server-challenge
#   HOST, PORT    127.0.0.1:3000 behind Nginx; 0.0.0.0:80 if serving directly
#
# Optional tuning knobs we support (forwarded like everything else):
#   THREADS, DB_CONNS, DB_READ_CONNS, DB_WRITE_CONNS, BCRYPT_THREADS, BCRYPT_LANES, BCRYPT_WAIT_MS,
#   PG_DEPTH, PG_SESSION, STATS
#
# `exec` replaces the shell so the process hands SIGTERM/SIGINT straight to
# the binary and systemd's MainPID is bin/conduit itself.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -x bin/conduit ]; then
  echo "start.sh: bin/conduit not built — run ./build.sh first" >&2
  exit 1
fi

# 20k+ connections need fds far past the usual 1024 default; the binary also
# raises its own rlimit at startup, but the shell limit must allow it first.
ulimit -n 200000 2>/dev/null || ulimit -n hard 2>/dev/null || true

# Limited-app layout: the server pins itself to CPUs 0-3 (taskset below) and
# leaves the rest of the box free for Postgres backends. Every knob below is
# a default (`:=`), so an explicitly-provided environment (the benchmark
# harness's HOST/PORT, or --env THREADS=/DB_CONNS=/... overrides) always wins.
: "${HOST:=0.0.0.0}"
: "${PORT:=80}"
export HOST PORT
: "${THREADS:=1}"
# Fallback on roomier boxes if one loop saturates: THREADS=2.
export THREADS
: "${DB_CONNS:=32}"
export DB_CONNS
: "${DB_READ_CONNS:=24}"
: "${DB_WRITE_CONNS:=8}"
export DB_READ_CONNS DB_WRITE_CONNS
: "${BCRYPT_THREADS:=2}"
: "${BCRYPT_LANES:=4}"
: "${BCRYPT_WAIT_MS:=40}"
export BCRYPT_THREADS BCRYPT_LANES BCRYPT_WAIT_MS
: "${PG_DEPTH:=16}"
export PG_DEPTH
: "${PG_SESSION:=plan_cache_mode=force_generic_plan,jit=off,max_parallel_workers_per_gather=0}"
export PG_SESSION

# Self-pin only: taskset confines bin/conduit (and the affinity mask its
# server.c pinning reads via sched_getaffinity) to 0-3. Postgres PIDs are
# never touched — they remain free to run on the remaining CPUs.
if command -v taskset >/dev/null 2>&1; then
  exec taskset -c 0-3 ./bin/conduit
else
  exec ./bin/conduit
fi
