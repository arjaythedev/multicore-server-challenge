#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: CHICKEN 5.4.0 from the official tarball (sha256-checked) -> /opt/chicken,
# plus the C toolchain and libpq headers the eggs build against.
set -euo pipefail
CHICKEN_VERSION=5.4.0
CHICKEN_SHA256=3c5d4aa61c1167bf6d9bf9eaf891da7630ba9f5f3c15bf09515a7039bfcdec5f
PREFIX="${CHICKEN_PREFIX:-/opt/chicken}"
apt-get update -q && apt-get install -y -q build-essential curl ca-certificates libpq-dev libcrypt-dev
TMP="$(mktemp -d)"
curl -fsSLo "$TMP/chicken.tgz" "https://code.call-cc.org/releases/$CHICKEN_VERSION/chicken-$CHICKEN_VERSION.tar.gz"
echo "$CHICKEN_SHA256  $TMP/chicken.tgz" | sha256sum -c -
tar -C "$TMP" -xzf "$TMP/chicken.tgz"
make -C "$TMP/chicken-$CHICKEN_VERSION" -j"$(nproc)" PREFIX="$PREFIX"
make -C "$TMP/chicken-$CHICKEN_VERSION" PREFIX="$PREFIX" install
rm -rf "$TMP"
# Ask the official egg server (code.call-cc.org) first; the mirror listed ahead of it often times out.
DEFAULTS="$PREFIX/share/chicken/setup.defaults"
sed -i '/^(server "kitten-technologies")$/d; s/^(server "call-cc")$/(server "call-cc")\n(server "kitten-technologies")/' "$DEFAULTS"
grep '^(server' "$DEFAULTS"
"$PREFIX/bin/csi" -version
