#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT.
# Postgres connections (DB_POOL_SIZE, all the server opens): default 3 per core, capped at 95 (SPEC.md: max_connections = 100).
set -euo pipefail
export PATH="/opt/swift/usr/bin:$PATH"
DIR="$(cd "$(dirname "$0")" && pwd)"
NPROC="$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
DEFAULT_POOL=$(( 3 * NPROC ))
[ "$DEFAULT_POOL" -gt 95 ] && DEFAULT_POOL=95
export DB_POOL_SIZE="${DB_POOL_SIZE:-$DEFAULT_POOL}"
# jemalloc in place of glibc malloc when install.sh put it there (measured on Linux: about 5% less server CPU per
# request, and steadier); without it the server runs on glibc malloc as before.
for lib in /usr/lib/x86_64-linux-gnu/libjemalloc.so.2 /usr/lib/aarch64-linux-gnu/libjemalloc.so.2; do
  if [ -f "$lib" ]; then export LD_PRELOAD="$lib${LD_PRELOAD:+:$LD_PRELOAD}"; break; fi
done
exec "$DIR/.build/release/Conduit"
