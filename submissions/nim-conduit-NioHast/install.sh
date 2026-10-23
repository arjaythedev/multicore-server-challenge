#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04 x86_64.
set -euo pipefail
apt-get update -q
apt-get install -y -q build-essential curl ca-certificates xz-utils \
  libpq-dev libcrypt-dev libssl-dev

NIM_VERSION=2.2.12
NIM_TARBALL="nim-${NIM_VERSION}-linux_x64.tar.xz"
NIM_SHA256="7df1611449a6842af69322aa2c1206942982650a5f6bc0d37bc8ec109932f638"
DEST=/opt/nim

if [ ! -x "$DEST/bin/nim" ] || ! "$DEST/bin/nim" --version >/dev/null 2>&1; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "https://nim-lang.org/download/$NIM_TARBALL" -o "$tmp/nim.tar.xz"
  echo "$NIM_SHA256  $tmp/nim.tar.xz" | sha256sum -c -
  tar -xJf "$tmp/nim.tar.xz" -C "$tmp"
  rm -rf "$DEST"
  mv "$tmp/nim-${NIM_VERSION}" "$DEST"
  ln -sf "$DEST/bin/nim" /usr/local/bin/nim
fi
"$DEST/bin/nim" --version
