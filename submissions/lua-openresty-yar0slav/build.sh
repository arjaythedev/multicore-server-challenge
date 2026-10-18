#!/usr/bin/env bash
# Builds as a normal user: downloads the one dependency (pgmoon, pure Lua) at a pinned version and checksum,
# then byte-compiles every Lua file as a syntax check. Nothing is compiled to native code.
set -euo pipefail
cd "$(dirname "$0")"
PGMOON_VERSION=1.18.0
PGMOON_SHA256=1d11cde905533a76911808c0930470638fba10415f2ac4fe15c3edfd55edae55

rm -rf vendor && mkdir -p vendor
curl -fsSL "https://github.com/leafo/pgmoon/archive/refs/tags/v$PGMOON_VERSION.tar.gz" -o vendor/pgmoon.tar.gz
echo "$PGMOON_SHA256  vendor/pgmoon.tar.gz" | sha256sum -c --quiet -
tar -xzf vendor/pgmoon.tar.gz -C vendor
mv "vendor/pgmoon-$PGMOON_VERSION/pgmoon" vendor/pgmoon
rm -rf "vendor/pgmoon-$PGMOON_VERSION" vendor/pgmoon.tar.gz

for f in lua/*.lua vendor/pgmoon/*.lua; do /usr/local/openresty/luajit/bin/luajit -b "$f" /dev/null; done
echo "build ok"
