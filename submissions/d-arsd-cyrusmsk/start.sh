#!/usr/bin/env bash
# Runs the server in the foreground. Configured only by the SPEC.md env vars:
# DATABASE_URL, JWT_SECRET, HOST, PORT. Optional: ARSD_THREADS (worker threads,
# default: 2*cores+1), ARSD_FIBER_STACK (bytes, default 65536).
set -euo pipefail
cd "$(dirname "$0")"

# mimalloc as the C allocator (libpq hot paths) when it is installed. The D GC
# manages its own mmap'd pools and is unaffected; this only swaps the libc
# malloc underneath the C libraries. Set MIMALLOC=0 to skip it.
MI_PATH=""
for p in /usr/lib/x86_64-linux-gnu/libmimalloc.so /usr/lib/aarch64-linux-gnu/libmimalloc.so; do
  [ -f "$p" ] && MI_PATH="$p" && break
done
if [ "${MIMALLOC:-1}" = 1 ] && [ -n "$MI_PATH" ]; then
  export LD_PRELOAD="${MI_PATH}${LD_PRELOAD:+:$LD_PRELOAD}"
  echo "start.sh: preloading mimalloc ($LD_PRELOAD)" >&2
fi

exec ./bin/server
