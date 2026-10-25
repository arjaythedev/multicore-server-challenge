#!/usr/bin/env bash
# Builds the app as a normal user: installs the gems pinned in Gemfile.lock into ./vendor/bundle. Native gems
# (pg, bcrypt, json, the event loop) compile from source rather than coming as prebuilt platform gems.
set -euo pipefail
cd "$(dirname "$0")"
RUBY_BIN=/opt/ruby-4.0.9/bin
[ -x "$RUBY_BIN/ruby" ] || RUBY_BIN="$(dirname "$(command -v ruby)")"   # local development: ruby on PATH
export PATH="$RUBY_BIN:$PATH"

bundle config set --local deployment true
bundle config set --local force_ruby_platform true
bundle install --jobs "$(nproc)"
bundle exec ruby -e 'require "./lib/conduit"; require "falcon/version"
  puts "build ok: #{RUBY_DESCRIPTION}, falcon #{Falcon::VERSION}, pg #{PG::VERSION}"'
