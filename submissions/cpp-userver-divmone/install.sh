#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: installs userver 3.2 from the official userver release package for
# Ubuntu 24.04 (pinned by version and SHA-256). apt pulls in its dependencies (g++, cmake, ninja, Boost, libpq,
# OpenSSL, ...) from the Ubuntu archive.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
USERVER_VERSION=3.2
USERVER_DEB="ubuntu24.04-libuserver-all-dev_${USERVER_VERSION}_amd64.deb"
USERVER_SHA256=26bc0d889bb7d71c68fa46f1f2061adf2e6c1c4a27a7b366cf2072dfd16de88a

apt-get update -q
apt-get install -y -q --no-install-recommends ca-certificates curl

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL --retry 3 -o "$TMP/$USERVER_DEB" \
  "https://github.com/userver-framework/userver/releases/download/v${USERVER_VERSION}/${USERVER_DEB}"
echo "$USERVER_SHA256  $TMP/$USERVER_DEB" | sha256sum -c -
chmod a+r "$TMP" "$TMP/$USERVER_DEB"   # apt's sandbox user must be able to read the local .deb
apt-get install -y -q --no-install-recommends "$TMP/$USERVER_DEB" libcrypt-dev

g++ --version | head -1
cmake --version | head -1
dpkg-query -W libuserver-all-dev libpq-dev libssl-dev libcrypt-dev
