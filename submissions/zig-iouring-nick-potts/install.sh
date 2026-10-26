#!/usr/bin/env bash
# Installs the pinned Zig toolchain (official tarball, checksummed) to /opt/zig-0.17.0 and links /usr/local/bin/zig.
# Run as root. Nothing else is needed: the server talks to the kernel and Postgres directly.
set -euo pipefail
ZIG_VER=0.17.0
ZIG_SHA=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026
DEST=/opt/zig-$ZIG_VER
if [ -x "$DEST/zig" ] && [ "$("$DEST/zig" version)" = "$ZIG_VER" ]; then
  ln -sf "$DEST/zig" /usr/local/bin/zig
  exit 0
fi
command -v curl >/dev/null && command -v xz >/dev/null || { apt-get update -q && apt-get install -yq curl xz-utils; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL "https://ziglang.org/download/$ZIG_VER/zig-x86_64-linux-$ZIG_VER.tar.xz" -o "$TMP/zig.tar.xz"
echo "$ZIG_SHA  $TMP/zig.tar.xz" | sha256sum -c -
tar -C "$TMP" -xf "$TMP/zig.tar.xz"
rm -rf "$DEST"
mv "$TMP/zig-x86_64-linux-$ZIG_VER" "$DEST"
ln -sf "$DEST/zig" /usr/local/bin/zig
"$DEST/zig" version
