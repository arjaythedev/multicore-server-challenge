#!/usr/bin/env bash
# Runs the release in the foreground. Required: DATABASE_URL, JWT_SECRET, HOST, PORT. Optional tunables (README.md):
# SCHEDULERS, DIRTY_CPU, READ_CONNS, WRITE_CONNS, BATCH_MAX, BATCH_INFLIGHT, BCRYPT_WORKERS, BCRYPT_WINDOW_MS, ACCEPTORS.
set -euo pipefail
cd "$(dirname "$0")"
cores=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN)
# Postgres needs ~3x the CPU we do per request, so the VM gets about half the cores' worth of schedulers; extra
# runnable threads would only preempt Postgres. Idle schedulers sleep instead of spinning (+sbwt none).
sched=$(( cores / 2 )); (( sched >= 2 )) || sched=2
dirty=$(( cores / 4 )); (( dirty >= 2 )) || dirty=2
SCHEDULERS="${SCHEDULERS:-$sched:$sched}"
DIRTY_CPU="${DIRTY_CPU:-$dirty:$dirty}"
export BCRYPT_WORKERS="${BCRYPT_WORKERS:-${DIRTY_CPU%%:*}}"
# +P/+Q: one process and one port per keep-alive connection (the defaults would cap connections at 65536).
export ERL_AFLAGS="+S $SCHEDULERS +SDcpu $DIRTY_CPU +SDio 1 +sbwt none +sbwtdcpu none +sbwtdio none +P 4000000 +Q 1000000 ${ERL_AFLAGS:-}"
export RELEASE_DISTRIBUTION=none LANG=C.UTF-8
exec _build/prod/rel/conduit/bin/conduit start
