#!/usr/bin/env bash
set -euo pipefail
RUBY_VERSION=4.0.9
RUBY_SHA256=c35350682ff050b79702d57ade4516e7336063f510155d19fb2fb5b3f3909511
PREFIX=/opt/ruby-$RUBY_VERSION

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
# rustc is for building YJIT.
apt-get install -y -q --no-install-recommends build-essential pkg-config curl ca-certificates rustc \
  libssl-dev libyaml-dev zlib1g-dev libffi-dev libgmp-dev libreadline-dev libjemalloc-dev libpq-dev tzdata

if [ ! -x "$PREFIX/bin/ruby" ]; then
  SRC="$(mktemp -d)"
  curl -fsSL -o "$SRC/ruby.tar.gz" "https://cache.ruby-lang.org/pub/ruby/${RUBY_VERSION%.*}/ruby-$RUBY_VERSION.tar.gz"
  echo "$RUBY_SHA256  $SRC/ruby.tar.gz" | sha256sum -c -
  tar -xzf "$SRC/ruby.tar.gz" -C "$SRC"
  (cd "$SRC/ruby-$RUBY_VERSION" &&
    ./configure --prefix="$PREFIX" --enable-yjit --with-jemalloc --disable-install-doc &&
    make -j"$(nproc)" && make install)
  rm -rf "$SRC"
fi
chmod -R a+rX "$PREFIX"
"$PREFIX/bin/ruby" --yjit -e 'abort "YJIT missing" unless RubyVM::YJIT.enabled?; puts "#{RUBY_DESCRIPTION}"'
