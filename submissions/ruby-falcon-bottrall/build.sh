#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
RUBY_BIN=/opt/ruby-4.0.9/bin
[ -x "$RUBY_BIN/ruby" ] || RUBY_BIN="$(dirname "$(command -v ruby)")"   # local development: ruby on PATH
export PATH="$RUBY_BIN:$PATH"

bundle config set --local deployment true
bundle config set --local force_ruby_platform true # build native gems from source, not prebuilt binaries
bundle install --jobs "$(nproc)"
bundle exec ruby -e 'require "./lib/conduit"; require "falcon/version"
  puts "build ok: #{RUBY_DESCRIPTION}, falcon #{Falcon::VERSION}, pg #{PG::VERSION}"'
