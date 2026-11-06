#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT (and the optional IO_THREADS,
# READ_LANES, WRITE_LANES, BCRYPT_THREADS, BCRYPT_LANES, as the Rust reads them).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
# jemalloc in place of glibc malloc when install.sh put it there: Swift allocates more small objects than the Rust.
for lib in /usr/lib/x86_64-linux-gnu/libjemalloc.so.2 /usr/lib/aarch64-linux-gnu/libjemalloc.so.2; do
  if [ -f "$lib" ]; then export LD_PRELOAD="$lib${LD_PRELOAD:+:$LD_PRELOAD}"; break; fi
done
exec "$DIR/.build/release/Conduit"
