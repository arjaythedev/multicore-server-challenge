#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: installs the Swift toolchain in /usr/local.
set -euo pipefail

apt-get update -q
apt-get install -y -q \
  binutils ca-certificates curl git gnupg2 libc6-dev libcurl4-openssl-dev libedit2 \
  libgcc-13-dev libncurses-dev libpython3-dev libsqlite3-0 libstdc++-13-dev \
  libxml2-dev libz3-dev pkg-config tzdata unzip zlib1g-dev

SWIFT_VERSION=6.4.2
TARBALL="swift-${SWIFT_VERSION}-RELEASE-ubuntu24.04.tar.gz"
URL="https://download.swift.org/swift-${SWIFT_VERSION}-release/ubuntu2404/swift-${SWIFT_VERSION}-RELEASE/${TARBALL}"

curl -fsSL -o "/tmp/${TARBALL}" "$URL"
mkdir -p /usr/local/swift
tar xzf "/tmp/${TARBALL}" -C /usr/local/swift --strip-components=1
rm -f "/tmp/${TARBALL}"
ln -sf /usr/local/swift/usr/bin/swift /usr/local/bin/swift
ln -sf /usr/local/swift/usr/bin/swiftc /usr/local/bin/swiftc

swift --version
