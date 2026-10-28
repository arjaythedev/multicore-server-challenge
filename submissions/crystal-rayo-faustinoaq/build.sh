#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p bin
shards install --frozen --without-development
# Avoid Crystal runtime thread state surviving Rayo worker forks. Bcrypt owns
# its raw pthreads; request validation still uses the normal garbage collector.
crystal build -Dwithout_mt --release --no-debug --mcpu x86-64-v3 src/server.cr -o bin/server
