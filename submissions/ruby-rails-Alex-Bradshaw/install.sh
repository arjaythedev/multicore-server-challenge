#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: builds Ruby 4.0.0 from the official ruby-lang.org tarball into
# /opt/ruby, then installs the exact Bundler version Gemfile.lock was made with.
set -euo pipefail
RUBY_VERSION=4.0.0
BUNDLER_VERSION=4.0.9

apt-get update -q
# libjemalloc2 is a faster memory allocator that start.sh loads into Ruby (see there).
# Ruby's build dependencies, plus libpq-dev for the pg gem, and rustc so Ruby is built with YJIT (its JIT
# compiler, which Rails 8 turns on automatically when it's available).
apt-get install -y -q curl ca-certificates build-essential autoconf libssl-dev libyaml-dev zlib1g-dev \
  libffi-dev libgmp-dev libreadline-dev libpq-dev rustc libjemalloc2

src="$(mktemp -d)"
curl -fsSL "https://cache.ruby-lang.org/pub/ruby/${RUBY_VERSION%.*}/ruby-${RUBY_VERSION}.tar.gz" | tar xz -C "$src"
cd "$src/ruby-${RUBY_VERSION}"
./configure --prefix=/opt/ruby --disable-install-doc
make -j"$(nproc)"
make install
cd / && rm -rf "$src"

/opt/ruby/bin/gem install bundler -v "$BUNDLER_VERSION" --no-document
chmod -R a+rX /opt/ruby
/opt/ruby/bin/ruby -v && /opt/ruby/bin/bundle -v
# Fail the install if YJIT didn't get built in.
/opt/ruby/bin/ruby --yjit -e 'abort "Ruby was built without YJIT" unless RubyVM::YJIT.enabled?; puts "YJIT ok"'
