#!/usr/bin/env bash
# Runs the server in the foreground. WORKERS, BCRYPT_THREADS and PG_CONNECTIONS override the defaults for tuning runs.
set -euo pipefail
cd "$(dirname "$0")"
ulimit -n "$(ulimit -Hn)"
# Postgres is on the same box, over loopback: TLS would only burn CPU on both ends.
export PGSSLMODE="${PGSSLMODE:-disable}"
export OCAMLRUNPARAM="${OCAMLRUNPARAM:-s=32M,o=400}"
# SCHED_BATCH: the scheduler gives each thread longer slices before preempting it, which suits threads that each run
# an event loop. Plain SCHED_OTHER if chrt is missing.
if command -v chrt >/dev/null; then exec chrt -b 0 ./_build/default/src/main.exe; fi
exec ./_build/default/src/main.exe
