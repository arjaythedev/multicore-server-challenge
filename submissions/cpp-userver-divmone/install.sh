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

# userver links libpq statically and uses its internals (PGconn), so the libpq it links must be the major version
# the package was built against: 16, from the Ubuntu archive. With the PGDG repo (the benchmark box, GitHub's
# runners) apt installs libpq 18 instead, which can't be mixed with the PostgreSQL 16 libpgcommon/userver objects.
# So unpack Ubuntu's libpq-dev 16 next to it (not installed: libpq5 18 stays as it is) for CMakeLists.txt to use.
LIBPQ16_DIR=/opt/conduit/libpq16
# awk reads all of apt-cache's output (no early exit): quitting early would kill apt-cache with SIGPIPE, and
# pipefail + set -e would then end this script silently.
LIBPQ16_VERSION="$(apt-cache madison libpq-dev | awk -F'|' '!v && $2 ~ /^ *16\..*ubuntu/ {v = $2; gsub(/ /, "", v)} END {print v}')"
[ -n "$LIBPQ16_VERSION" ] || { echo "no libpq-dev 16 in the Ubuntu archive"; exit 1; }
(cd "$TMP" && apt-get download -q "libpq-dev=$LIBPQ16_VERSION")
rm -rf "$LIBPQ16_DIR" && mkdir -p "$LIBPQ16_DIR"
dpkg-deb -x "$TMP"/libpq-dev_*.deb "$LIBPQ16_DIR"
chmod -R a+rX /opt/conduit
test -f "$LIBPQ16_DIR/usr/lib/x86_64-linux-gnu/libpq.a"
test -f /usr/lib/postgresql/16/lib/libpgcommon.a   # postgresql-server-dev-16, a dependency of the userver package

g++ --version | sed -n 1p
cmake --version | sed -n 1p
dpkg-query -W libuserver-all-dev libpq-dev postgresql-server-dev-16 libssl-dev libcrypt-dev
echo "libpq for userver: libpq-dev $LIBPQ16_VERSION in $LIBPQ16_DIR"
