#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: Swift 6.4.1 (official tarball, sha256-checked) -> /opt/swift.
set -euo pipefail
SWIFT_VERSION=6.4.1
SHA256=7d246c7114077ad01dba4ad897628446ada4c489d6c7dbcf39ae3f25cbe17e8b

apt-get update -q
apt-get install -y -q \
  binutils curl git gnupg2 libc6-dev libcurl4-openssl-dev libedit2 libgcc-13-dev \
  libncurses-dev libpython3-dev libsqlite3-0 libstdc++-13-dev libxml2-dev libz3-dev \
  pkg-config tzdata unzip zlib1g-dev ca-certificates

TARBALL="swift-$SWIFT_VERSION-RELEASE-ubuntu24.04.tar.gz"
curl -fsSLo "/tmp/$TARBALL" \
  "https://download.swift.org/swift-$SWIFT_VERSION-release/ubuntu2404/swift-$SWIFT_VERSION-RELEASE/$TARBALL"
echo "$SHA256  /tmp/$TARBALL" | sha256sum -c -
rm -rf /opt/swift && mkdir -p /opt/swift
tar -C /opt/swift -xzf "/tmp/$TARBALL" --strip-components=1
rm "/tmp/$TARBALL"
for bin in swift swiftc; do ln -sf "/opt/swift/usr/bin/$bin" "/usr/local/bin/$bin"; done
swift --version
