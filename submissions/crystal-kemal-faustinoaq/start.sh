#!/usr/bin/env bash
# One Kemal process per core, all on HOST:PORT with SO_REUSEPORT (the kernel spreads
# incoming connections over them). Stays in the foreground until they exit.
cd "$(dirname "$0")"
export WORKERS="${WORKERS:-$(nproc)}"
pids=()
for _ in $(seq "$WORKERS"); do bin/server & pids+=($!); done
trap 'kill "${pids[@]}" 2>/dev/null' TERM INT
wait
