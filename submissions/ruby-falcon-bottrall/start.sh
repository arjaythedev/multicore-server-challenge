#!/usr/bin/env bash
# Runs Falcon in the foreground: WEB_CONCURRENCY forked workers (default: one per core), each with one pipelined
# Postgres connection for reads and up to DB_POOL more for writes. Config: DATABASE_URL, JWT_SECRET, HOST, PORT.
set -euo pipefail
cd "$(dirname "$0")"
RUBY_BIN=/opt/ruby-4.0.9/bin
[ -x "$RUBY_BIN/ruby" ] || RUBY_BIN="$(dirname "$(command -v ruby)")"   # local development: ruby on PATH
export PATH="$RUBY_BIN:$PATH"

export LANG="${LANG:-C.UTF-8}"
export WEB_CONCURRENCY="${WEB_CONCURRENCY:-$(nproc)}"
export DB_POOL="${DB_POOL:-2}"
export RUBYOPT="-W:no-experimental"   # async-container uses IO::Buffer, which warns once per worker
# Start each worker with a heap that has room for a lot of requests' garbage. Every GC, even a minor one,
# scans the stack of every connection's fiber (thousands per worker), so it costs 10-50 ms however little
# garbage there is: at the default heap size a worker collected twice a second and spent almost 30% of its CPU
# in GC. Slots per size pool (40, 80, 160 and 320 bytes), in proportion to what a request allocates.
export RUBY_GC_HEAP_0_INIT_SLOTS="${RUBY_GC_HEAP_0_INIT_SLOTS:-2000000}"
export RUBY_GC_HEAP_1_INIT_SLOTS="${RUBY_GC_HEAP_1_INIT_SLOTS:-600000}"
export RUBY_GC_HEAP_2_INIT_SLOTS="${RUBY_GC_HEAP_2_INIT_SLOTS:-200000}"
export RUBY_GC_HEAP_3_INIT_SLOTS="${RUBY_GC_HEAP_3_INIT_SLOTS:-20000}"

exec bundle exec falcon host falcon.rb
