#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: C/C++ toolchain, libpq + OpenSSL headers, and Node.js 24.11.0
# (official tarball, sha256-checked) -> /opt/node, symlinked to /usr/local/bin/node.
set -euo pipefail
NODE_VERSION=24.11.0
ARCH=linux-x64
export DEBIAN_FRONTEND=noninteractive

apt-get update -q
apt-get install -y -q build-essential pkg-config curl ca-certificates xz-utils libpq-dev libssl-dev

TARBALL="node-v$NODE_VERSION-$ARCH.tar.xz"
BASE="https://nodejs.org/dist/v$NODE_VERSION"
cd /tmp
curl -fsSLo "$TARBALL" "$BASE/$TARBALL"
curl -fsSLo SHASUMS256.txt "$BASE/SHASUMS256.txt"
grep " $TARBALL\$" SHASUMS256.txt | sha256sum -c -
rm -rf /opt/node && mkdir -p /opt/node
tar -xJf "$TARBALL" -C /opt/node --strip-components=1
rm -f "$TARBALL" SHASUMS256.txt
ln -sf /opt/node/bin/node /usr/local/bin/node
/opt/node/bin/node --version
