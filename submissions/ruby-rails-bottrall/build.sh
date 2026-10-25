#!/usr/bin/env bash
# Builds the app as a normal user: installs the gems pinned in Gemfile.lock into ./vendor/bundle. Native gems
# (pg, bcrypt, the JSON and HTTP parsers) compile from source rather than coming as prebuilt platform gems.
set -euo pipefail
cd "$(dirname "$0")"
RUBY_BIN=/opt/ruby-4.0.9/bin
[ -x "$RUBY_BIN/ruby" ] || RUBY_BIN="$(dirname "$(command -v ruby)")"   # local development: ruby on PATH
export PATH="$RUBY_BIN:$PATH"

bundle config set --local deployment true
bundle config set --local force_ruby_platform true
bundle install --jobs "$(nproc)"
bundle exec ruby --yjit -e 'require "rails"; require "falcon/version"
  puts "rails build ok: #{RUBY_DESCRIPTION}, rails #{Rails.version}, falcon #{Falcon::VERSION}"'
