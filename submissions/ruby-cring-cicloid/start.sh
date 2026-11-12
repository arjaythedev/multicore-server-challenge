#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT.
# Optional knobs (README): WORKERS (default 3/4 of the cores), PG_CONNECTIONS per worker (default 2),
# READ_WINDOW_MS, READ_LANES, READ_MAX, BCRYPT_THREADS, PLANNERS, CONNECTIONS=epoll.
set -euo pipefail
cd "$(dirname "$0")"
ulimit -Sn "$(ulimit -Hn)" 2>/dev/null || true
export PATH="/opt/ruby/bin:$PATH"
export RUBY_YJIT_ENABLE=1
# A heap with more free slots after each GC (and that keeps them) means fewer minor GCs.
# Defaults; any of these already in the environment wins (for A/B runs). A bigger starting heap: at
# 52,000 users on the rig it passed 3 runs of 3 (p95 335-441 ms) where 600k/200k slots passed 1 of 4.
export RUBY_GC_HEAP_0_INIT_SLOTS="${RUBY_GC_HEAP_0_INIT_SLOTS:-1500000}" RUBY_GC_HEAP_1_INIT_SLOTS="${RUBY_GC_HEAP_1_INIT_SLOTS:-500000}"
export RUBY_GC_HEAP_FREE_SLOTS_MIN_RATIO="${RUBY_GC_HEAP_FREE_SLOTS_MIN_RATIO:-0.40}"
export RUBY_GC_HEAP_FREE_SLOTS_GOAL_RATIO="${RUBY_GC_HEAP_FREE_SLOTS_GOAL_RATIO:-0.60}"
export RUBY_GC_HEAP_FREE_SLOTS_MAX_RATIO="${RUBY_GC_HEAP_FREE_SLOTS_MAX_RATIO:-0.90}"
# Every response is a few KB of fresh string: with the default malloc limits that growth alone triggered
# most minor GCs. Locally, paired runs at 20,000 users: 37-40k req/s against 34-35k, p95 down by a third.
export RUBY_GC_MALLOC_LIMIT="${RUBY_GC_MALLOC_LIMIT:-67108864}" RUBY_GC_MALLOC_LIMIT_MAX="${RUBY_GC_MALLOC_LIMIT_MAX:-268435456}"
export RUBY_GC_OLDMALLOC_LIMIT="${RUBY_GC_OLDMALLOC_LIMIT:-134217728}" RUBY_GC_OLDMALLOC_LIMIT_MAX="${RUBY_GC_OLDMALLOC_LIMIT_MAX:-536870912}"
# Compile after 5 calls instead of 30, so paths the warm-up doesn't cover run compiled code almost at once.
exec bundle exec ruby --yjit --yjit-call-threshold=5 server.rb
