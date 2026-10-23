#!/usr/bin/env bash
# Runs the server in the foreground. Configured only by the SPEC.md env vars:
# DATABASE_URL, JWT_SECRET, HOST, PORT. Optional: CONNS (max Postgres
# connections overall, default 95, capped at 95; invalid values use 95, and
# values below the scheduler count are rejected). The scheduler count follows
# the CPU affinity mask; use taskset to change it.
set -euo pipefail
cd "$(dirname "$0")"

# mimalloc as the C allocator (libpq, OpenSSL and zlib hot paths) when it is
# installed. The D GC manages its own mmap'd pools and is unaffected; this only
# swaps the libc malloc underneath the C libraries. Set MIMALLOC=0 to skip it.
MI_PATH=""
for p in /usr/lib/x86_64-linux-gnu/libmimalloc.so /usr/lib/aarch64-linux-gnu/libmimalloc.so; do
  [ -f "$p" ] && MI_PATH="$p" && break
done
if [ "${MIMALLOC:-1}" = 1 ] && [ -n "$MI_PATH" ]; then
  export LD_PRELOAD="${MI_PATH}${LD_PRELOAD:+:$LD_PRELOAD}"
  echo "start.sh: preloading mimalloc ($LD_PRELOAD)" >&2
fi

exec ./bin/server
