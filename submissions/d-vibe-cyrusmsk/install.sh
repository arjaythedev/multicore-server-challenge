#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: the D toolchain (LDC 1.41.0 with its
# own dub) into /usr/local/ldc, plus the two system libraries the app links.
#
# Pinned: the LDC tarball is checksum-verified, and every DUB package version is
# recorded in dub.selections.json.
set -euo pipefail

LDC_VERSION=1.41.0
LDC_SHA256=4a439457f0fe59e69d02fd6b57549fc3c87ad0f55ad9fb9e42507b6f8e327c8f
LDC_URL="https://github.com/ldc-developers/ldc/releases/download/v${LDC_VERSION}/ldc2-${LDC_VERSION}-linux-x86_64.tar.xz"

apt-get update -qq
# curl for the tarball, libpq for the Postgres client, libbsd for the bcrypt
# package's arc4random_buf, gcc because LDC links through it, git because dpq2
# pins one of its own dependencies (derelict-pq) by commit, and zlib because
# vibe-core's stream support links it (unused here, but linked in).
apt-get install -y -qq curl ca-certificates libpq-dev libbsd-dev gcc git zlib1g-dev

curl -fsSLo /tmp/ldc2.tar.xz "$LDC_URL"
echo "${LDC_SHA256}  /tmp/ldc2.tar.xz" | sha256sum -c -
rm -rf /usr/local/ldc
tar -C /usr/local -xJf /tmp/ldc2.tar.xz
mv "/usr/local/ldc2-${LDC_VERSION}-linux-x86_64" /usr/local/ldc
chmod -R a+rX /usr/local/ldc
rm -f /tmp/ldc2.tar.xz

/usr/local/ldc/bin/ldc2 --version
/usr/local/ldc/bin/dub --version
