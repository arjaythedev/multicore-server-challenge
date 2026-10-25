#!/usr/bin/env bash
# Runs Falcon in the foreground: WEB_CONCURRENCY forked workers (default: one per core), each with its own pool
# of DB_POOL Postgres connections. Config: DATABASE_URL, JWT_SECRET, HOST, PORT.
set -euo pipefail
cd "$(dirname "$0")"
RUBY_BIN=/opt/ruby-4.0.9/bin
[ -x "$RUBY_BIN/ruby" ] || RUBY_BIN="$(dirname "$(command -v ruby)")"   # local development: ruby on PATH
export PATH="$RUBY_BIN:$PATH"

export LANG="${LANG:-C.UTF-8}"
export WEB_CONCURRENCY="${WEB_CONCURRENCY:-$(nproc)}"
# 90 of Postgres's 100 connections, split evenly across the workers.
export DB_POOL="${DB_POOL:-$(( 90 / WEB_CONCURRENCY ))}"
export RUBYOPT="-W:no-experimental"   # async-container uses IO::Buffer, which warns once per worker

exec bundle exec falcon host falcon.rb
