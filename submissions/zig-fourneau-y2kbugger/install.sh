#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: Zig 0.17.0, its tarball checked
# against the sha256 ziglang.org publishes (download/index.json).
set -euo pipefail
ZIG_VERSION=0.17.0
ZIG_SHA256=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026
ZIG_DIR=/usr/local/zig-$ZIG_VERSION

apt-get update -qq
apt-get install -y -qq curl xz-utils ca-certificates

if [ ! -x "$ZIG_DIR/zig" ]; then
  tarball="$(mktemp)"
  curl -fsSL "https://ziglang.org/download/$ZIG_VERSION/zig-x86_64-linux-$ZIG_VERSION.tar.xz" -o "$tarball"
  echo "$ZIG_SHA256  $tarball" | sha256sum -c -
  mkdir -p "$ZIG_DIR"
  tar -xJf "$tarball" -C "$ZIG_DIR" --strip-components=1
  rm -f "$tarball"
fi
"$ZIG_DIR/zig" version
