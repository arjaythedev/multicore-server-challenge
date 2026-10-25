#!/usr/bin/env bash
# Runs Falcon in the foreground: WEB_CONCURRENCY forked workers (default: one per core), each with its own
# Active Record pool. Config: DATABASE_URL, JWT_SECRET, HOST, PORT.
set -euo pipefail
cd "$(dirname "$0")"
RUBY_BIN=/opt/ruby-4.0.9/bin
[ -x "$RUBY_BIN/ruby" ] || RUBY_BIN="$(dirname "$(command -v ruby)")"   # local development: ruby on PATH
export PATH="$RUBY_BIN:$PATH"

export RAILS_ENV=production
export LANG="${LANG:-C.UTF-8}"
export WEB_CONCURRENCY="${WEB_CONCURRENCY:-$(nproc)}"
# 90 of Postgres's 100 connections, split evenly across the workers.
export DB_POOL="${DB_POOL:-$(( 90 / WEB_CONCURRENCY ))}"
# Nothing in an API without cookies or sessions signs anything with it, but Rails wants one to boot.
export SECRET_KEY_BASE="${SECRET_KEY_BASE:-$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')}"
# YJIT is switched on by Rails (config.yjit) once the app has booted, before Falcon forks the workers.
# Start each worker with a heap big enough for a busy request mix, rather than growing it one GC at a time:
# this halves the time spent in GC. (Slots per size pool: 40, 80 and 160 bytes.)
export RUBY_GC_HEAP_0_INIT_SLOTS="${RUBY_GC_HEAP_0_INIT_SLOTS:-600000}"
export RUBY_GC_HEAP_1_INIT_SLOTS="${RUBY_GC_HEAP_1_INIT_SLOTS:-300000}"
export RUBY_GC_HEAP_2_INIT_SLOTS="${RUBY_GC_HEAP_2_INIT_SLOTS:-100000}"
export RUBYOPT="-W:no-experimental"   # async-container uses IO::Buffer, which warns once per worker

exec bundle exec falcon host falcon.rb
