#!/usr/bin/env bash
# Runs Rage (on Iodine) in the foreground: WEB_CONCURRENCY forked workers (default: one per core), each with its
# own Active Record pool. Config: DATABASE_URL, JWT_SECRET, HOST, PORT.
set -euo pipefail
cd "$(dirname "$0")"
RUBY_BIN=/opt/ruby-4.0.9/bin
[ -x "$RUBY_BIN/ruby" ] || RUBY_BIN="$(dirname "$(command -v ruby)")"   # local development: ruby on PATH
export PATH="$RUBY_BIN:$PATH"

export RAGE_ENV=production
export LANG="${LANG:-C.UTF-8}"
export WEB_CONCURRENCY="${WEB_CONCURRENCY:-$(nproc)}"
# 88 of Postgres's 100 connections, split evenly across the workers (the master holds one more from boot).
export DB_POOL="${DB_POOL:-$(( 88 / WEB_CONCURRENCY ))}"
# Rage only signs cookies and sessions with it, which a token API doesn't use.
export SECRET_KEY_BASE="${SECRET_KEY_BASE:-$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')}"
# Start each worker with a heap big enough for a busy request mix, rather than growing it one GC at a time.
# (Slots per size pool: 40, 80 and 160 bytes.) Same values as the Rails version.
export RUBY_GC_HEAP_0_INIT_SLOTS="${RUBY_GC_HEAP_0_INIT_SLOTS:-600000}"
export RUBY_GC_HEAP_1_INIT_SLOTS="${RUBY_GC_HEAP_1_INIT_SLOTS:-300000}"
export RUBY_GC_HEAP_2_INIT_SLOTS="${RUBY_GC_HEAP_2_INIT_SLOTS:-100000}"

export RUBYOPT="-W:no-experimental"   # Ruby warns once per worker that IO::Buffer (used by the fiber scheduler) is experimental

exec bundle exec rage s -b "${HOST:-127.0.0.1}" -p "${PORT:-3000}"
