#!/usr/bin/env bash
# Builds the app as a normal user: installs the gems pinned in Gemfile.lock into ./vendor/bundle. Native gems
# (pg, bcrypt, json, iodine) compile from source rather than coming as prebuilt platform gems.
set -euo pipefail
cd "$(dirname "$0")"
export PATH="/opt/ruby-4.0.9/bin:$PATH"   # installed by install.sh

bundle config set --local deployment true
bundle config set --local force_ruby_platform true
bundle install --jobs "$(nproc)"
bundle exec ruby --yjit -e 'require "rage"; require "sequel"
  puts "rage build ok: #{RUBY_DESCRIPTION}, rage #{Rage::VERSION}, sequel #{Sequel.version}"'
