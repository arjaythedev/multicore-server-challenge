#!/usr/bin/env bash
# Runs the release in the foreground. Required: DATABASE_URL, JWT_SECRET, HOST, PORT. Optional tunables: README.md,
# "Configuration" (SCHEDULERS and DIRTY_CPU are read here, the rest by the application).
set -euo pipefail
cd "$(dirname "$0")"
# One file descriptor per keep-alive connection: take the whole hard limit (the box's unit sets 200000 for both).
ulimit -n "$(ulimit -Hn)"
echo "open files limit: $(ulimit -n)"
# nproc honours the CPU affinity we were started with. Postgres burns about as much CPU per request as we do, so normal
# schedulers get ~5/8 of the cores (5 of 8) rather than all of them; extra runnable threads only preempt Postgres.
cores=$(nproc)
sched=$(( (cores * 5 + 4) / 8 )); (( sched >= 2 )) || sched=2
dirty=$(( cores / 4 )); (( dirty >= 2 )) || dirty=2
SCHEDULERS="${SCHEDULERS:-$sched:$sched}"
DIRTY_CPU="${DIRTY_CPU:-$dirty}"
# +sbwt none: idle schedulers sleep instead of spinning, leaving the cores to Postgres.
# +P/+Q: one process and one port per keep-alive connection; the defaults (262144 / 65536) are too low.
export ERL_AFLAGS="+S $SCHEDULERS +SDcpu $DIRTY_CPU:$DIRTY_CPU +SDio 2 +sbwt none +sbwtdcpu none +sbwtdio none +P 2000000 +Q 1000000 ${ERL_AFLAGS:-}"
# Distribution stays off unless asked for (RELEASE_DISTRIBUTION=sname: local profiling over `bin/conduit rpc`).
export RELEASE_DISTRIBUTION="${RELEASE_DISTRIBUTION:-none}" LANG=C.UTF-8
exec _build/prod/rel/conduit/bin/conduit start
