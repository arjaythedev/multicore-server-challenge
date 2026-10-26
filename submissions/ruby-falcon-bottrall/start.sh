#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
RUBY_BIN=/opt/ruby-4.0.9/bin
[ -x "$RUBY_BIN/ruby" ] || RUBY_BIN="$(dirname "$(command -v ruby)")"   # local development: ruby on PATH
export PATH="$RUBY_BIN:$PATH"

export LANG="${LANG:-C.UTF-8}"
export WEB_CONCURRENCY="${WEB_CONCURRENCY:-$(nproc)}"
export DB_POOL="${DB_POOL:-2}"
export RUBYOPT="-W:no-experimental"   # async-container uses IO::Buffer, which warns once per worker
# Every GC, even a minor one, scans the stack of each connection fiber (thousands per worker), so a GC costs
# 10-50 ms however little garbage there is. Starting with a big heap means far fewer of them.
export RUBY_GC_HEAP_0_INIT_SLOTS="${RUBY_GC_HEAP_0_INIT_SLOTS:-2000000}"
export RUBY_GC_HEAP_1_INIT_SLOTS="${RUBY_GC_HEAP_1_INIT_SLOTS:-600000}"
export RUBY_GC_HEAP_2_INIT_SLOTS="${RUBY_GC_HEAP_2_INIT_SLOTS:-200000}"
export RUBY_GC_HEAP_3_INIT_SLOTS="${RUBY_GC_HEAP_3_INIT_SLOTS:-20000}"

exec bundle exec falcon host falcon.rb
