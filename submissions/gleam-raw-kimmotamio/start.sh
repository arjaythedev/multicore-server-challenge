#!/usr/bin/env bash
# Runs the server in the foreground. Required: DATABASE_URL, JWT_SECRET, HOST, PORT.
# Optional tunables: SCHEDULERS (normal schedulers, default ~5/8 of the cores), DIRTY_CPU (bcrypt threads),
# DB_READ_CONNS, DB_WRITE_CONNS (Postgres connections), ACCEPTORS.
set -euo pipefail
cd "$(dirname "$0")"
export PATH="/usr/local/otp/bin:$PATH"
# One socket per connection: use the file-descriptor limit the service gets (LimitNOFILE=200000 on the box).
ulimit -n 200000 2>/dev/null || ulimit -n "$(ulimit -Hn)" 2>/dev/null || true
cores=$(nproc 2>/dev/null || sysctl -n hw.ncpu)
sched=$(( (cores * 5 + 4) / 8 )); (( sched >= 2 )) || sched=2
dirty=$(( cores / 4 )); (( dirty >= 2 )) || dirty=2
export SCHEDULERS="${SCHEDULERS:-$sched}"
export DIRTY_CPU="${DIRTY_CPU:-$dirty}"
export DB_READ_CONNS="${DB_READ_CONNS:-12}"
export DB_WRITE_CONNS="${DB_WRITE_CONNS:-8}"
export ACCEPTORS="${ACCEPTORS:-16}"
# +sbwt none: idle schedulers sleep instead of spinning, leaving the cores to Postgres.
# +P/+Q: one process and one port per keep-alive connection; the defaults are too low for tens of thousands.
exec erl -pa build/erlang-shipment/*/ebin \
  +S "$SCHEDULERS:$SCHEDULERS" +SDcpu "$DIRTY_CPU:$DIRTY_CPU" +SDio 2 \
  +sbwt none +sbwtdcpu none +sbwtdio none \
  +P 2000000 +Q 1000000 +K true \
  -noshell -noinput ${ERL_EXTRA:-} \
  -eval 'conduit@@main:run(conduit)'
