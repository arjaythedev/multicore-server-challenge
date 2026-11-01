#!/usr/bin/env bash
# Build and install the Nelua compiler, pinned to a commit, into /opt/nelua, plus the C toolchain and the C
# libraries the program links with: libpq (Postgres), OpenSSL (HMAC-SHA256) and ISA-L (gzip).
# Nelua has no versioned releases; its last commit is the pin.
# Idempotent; run as root.
set -euo pipefail
NELUA_COMMIT=a58450563e2d2ec49bff499865c8b5cfdf6ff81a   # master, 2025-06-24

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq build-essential git ca-certificates libpq-dev libssl-dev libisal-dev >/dev/null

if [ "$(cat /opt/nelua/COMMIT 2>/dev/null)" = "$NELUA_COMMIT" ]; then
  echo "nelua $NELUA_COMMIT already in /opt/nelua"
else
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  git -C "$tmp" init -q
  git -C "$tmp" fetch -q --depth 1 https://github.com/edubart/nelua-lang.git "$NELUA_COMMIT"
  git -C "$tmp" checkout -q FETCH_HEAD
  [ "$(git -C "$tmp" rev-parse HEAD)" = "$NELUA_COMMIT" ]
  rm -rf /opt/nelua
  make -C "$tmp" -s -j"$(nproc)" PREFIX=/opt/nelua install >/dev/null
  echo "$NELUA_COMMIT" > /opt/nelua/COMMIT
fi
/opt/nelua/bin/nelua --version | head -3
