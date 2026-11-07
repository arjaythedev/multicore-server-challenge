#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: rustup with Rust 1.99.0 in /usr/local (readable by every user).
# build-essential is needed by ring and mimalloc (C/asm parts).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

RUST_VERSION=1.99.1
PREFIX=/opt/rust

apt-get update -q
apt-get install -y -q --no-install-recommends build-essential pkg-config curl ca-certificates xz-utils

if ! { [ -x "$PREFIX/bin/rustc" ] && "$PREFIX/bin/rustc" --version | grep -q "^rustc $RUST_VERSION "; }; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl --proto '=https' --tlsv1.2 -fsSL \
    "https://static.rust-lang.org/dist/rust-${RUST_VERSION}-x86_64-unknown-linux-gnu.tar.xz" \
    -o "$tmp/rust.tar.xz"
  tar -xJf "$tmp/rust.tar.xz" -C "$tmp"
  "$tmp/rust-${RUST_VERSION}-x86_64-unknown-linux-gnu/install.sh" \
    --prefix="$PREFIX" --disable-ldconfig --without=rust-docs
fi

"$PREFIX/bin/rustc" --version
"$PREFIX/bin/cargo" --version