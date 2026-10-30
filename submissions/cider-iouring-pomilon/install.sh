#!/usr/bin/env bash
# install.sh — runs once as root on clean Ubuntu 24.04
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  build-essential \
  cmake \
  git \
  curl \
  unzip \
  ca-certificates \
  libpq-dev \
  python3

CIDER_DIR=/opt/cider
CIDER_COMMIT=f44fd0727f932fe22859eb7ca58d755d092a8317

cider_ok=0
if [ -x "$CIDER_DIR/build/cider" ] && [ -d "$CIDER_DIR/.git" ]; then
  if [ "$(git -C "$CIDER_DIR" rev-parse HEAD 2>/dev/null || true)" = "$CIDER_COMMIT" ]; then
    cider_ok=1
  fi
fi
if [ "$cider_ok" = 0 ]; then
  echo "== [Cider] Fetching and building Cider compiler from source..."
  rm -rf "$CIDER_DIR"
  git clone https://github.com/Pomilon/Cider.git "$CIDER_DIR"
  git -C "$CIDER_DIR" checkout -q "$CIDER_COMMIT"
  cmake -S "$CIDER_DIR" -B "$CIDER_DIR/build" -DCMAKE_BUILD_TYPE=Release
  cmake --build "$CIDER_DIR/build" -j"$(nproc)"
fi

echo "== [Cider] Compiler built successfully at $CIDER_DIR/build/cider"
