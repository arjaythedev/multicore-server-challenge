#!/usr/bin/env bash
# Runs Puma in the foreground. Configured only by DATABASE_URL, JWT_SECRET, HOST and PORT (SPEC.md runtime contract).
set -euo pipefail
cd "$(dirname "$0")"
# On the benchmark box (and in CI) Ruby comes from install.sh in /opt/ruby; locally, whatever Ruby is on PATH.
if [ -x /opt/ruby/bin/ruby ]; then export PATH="/opt/ruby/bin:$PATH"; fi
export BUNDLE_PATH=vendor/bundle BUNDLE_WITHOUT=development:test
export RAILS_ENV=production
# One Puma worker per core (8 on the box) with 5 threads each: 40 Postgres connections, under the 95 limit.
# Postgres and Nginx share these cores too, so fewer workers may do better: override WEB_CONCURRENCY to try it.
export WEB_CONCURRENCY="${WEB_CONCURRENCY:-$(nproc 2>/dev/null || sysctl -n hw.ncpu)}"
export RAILS_MAX_THREADS="${RAILS_MAX_THREADS:-5}"

# macOS only (local development): Puma forks its workers from a preloaded Rails app, and on macOS a forked
# process crashes the first time libpq touches the system's Kerberos/GSS or Objective-C libraries. Neither is
# needed for a plain password connection, so turn them off. Linux (the benchmark box and CI) doesn't have this.
if [ "$(uname)" = Darwin ]; then
  export PGGSSENCMODE=disable OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES
fi
# Production Rails refuses to boot without a secret_key_base. The API has no sessions or cookies,
# so nothing is signed with it and a fixed value is fine.
export SECRET_KEY_BASE=not-used-this-api-has-no-sessions
# jemalloc (installed by install.sh) instead of glibc's malloc: Ruby allocates constantly, and jemalloc is
# faster for that pattern and fragments memory far less across many threads. Linux only; skipped if absent.
for lib in /usr/lib/x86_64-linux-gnu/libjemalloc.so.2 /usr/lib/aarch64-linux-gnu/libjemalloc.so.2; do
  if [ -f "$lib" ]; then export LD_PRELOAD="$lib"; break; fi
done

exec bundle exec puma -C config/puma.rb
