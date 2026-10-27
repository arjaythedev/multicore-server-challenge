#!/usr/bin/env bash
# Builds the app as a normal user: installs the exact gem versions from Gemfile.lock into ./vendor/bundle.
# Uses env vars rather than `bundle config` so your local .bundle/config (and `bundle add`) is left alone.
set -euo pipefail
cd "$(dirname "$0")"
# On the benchmark box (and in CI) Ruby comes from install.sh in /opt/ruby; locally, whatever Ruby is on PATH.
if [ -x /opt/ruby/bin/ruby ]; then export PATH="/opt/ruby/bin:$PATH"; fi
export BUNDLE_PATH=vendor/bundle BUNDLE_WITHOUT=development:test BUNDLE_FROZEN=true
bundle install --jobs 4
ruby -v && bundle exec rails -v
