#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT.
# Optional: WORKERS (default: cores), PG_CONNECTIONS per worker (default 1), CONNECTIONS=epoll.
set -euo pipefail
cd "$(dirname "$0")"
ulimit -Sn "$(ulimit -Hn)" 2>/dev/null || true
export PATH="/opt/ruby/bin:$PATH"
export RUBY_YJIT_ENABLE=1
# A heap with more free slots after each GC (and that keeps them) means fewer minor GCs.
export RUBY_GC_HEAP_0_INIT_SLOTS=600000 RUBY_GC_HEAP_1_INIT_SLOTS=200000
export RUBY_GC_HEAP_FREE_SLOTS_MIN_RATIO=0.40 RUBY_GC_HEAP_FREE_SLOTS_GOAL_RATIO=0.60
export RUBY_GC_HEAP_FREE_SLOTS_MAX_RATIO=0.90
# Compile after 5 calls instead of 30, so paths the warm-up doesn't cover run compiled code almost at once.
exec bundle exec ruby --yjit --yjit-call-threshold=5 server.rb
