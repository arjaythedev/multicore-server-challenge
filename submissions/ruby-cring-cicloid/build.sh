#!/usr/bin/env bash
# Runs as a normal user: installs the pinned gems (Gemfile.lock) into vendor/bundle, compiling the native
# ones from source, then builds the Cring extension (ext/ring/), the io_uring connection layer, and
# BcryptLanes (ext/bcrypt/), checked against the single-hash code.
set -euo pipefail
cd "$(dirname "$0")"
export PATH="/opt/ruby/bin:$PATH"
bundle config set --local deployment true
bundle config set --local path vendor/bundle
bundle config set --local force_ruby_platform true
bundle install --jobs 4

# -march=native on x86_64 only, as in install.sh.
NATIVE=""
[ "$(uname -m)" = x86_64 ] && NATIVE="-march=native"
(cd ext/ring && NATIVE="$NATIVE" ruby extconf.rb > /dev/null && make clean > /dev/null && make)
(cd ext/shmq && NATIVE="$NATIVE" ruby extconf.rb > /dev/null && make clean > /dev/null && make)
(cd ext/fmt && NATIVE="$NATIVE" ruby extconf.rb > /dev/null && make clean > /dev/null && make)
(cd ext/jwt && NATIVE="$NATIVE" ruby extconf.rb > /dev/null && make clean > /dev/null && make)
(cd ext/bcrypt && NATIVE="$NATIVE" ruby extconf.rb > /dev/null && make clean > /dev/null && make)
ruby -r ./ext/bcrypt/bcrypt_lanes -e 'abort "bcrypt self-test failed" unless BcryptLanes.self_test'
