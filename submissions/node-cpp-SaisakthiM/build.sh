#!/usr/bin/env bash
# Builds the native addon -> build/conduit.node (vendored crypt_blowfish + the libuv/libpq addon). Idempotent.
# No node-gyp and no downloads: the Node tarball ships its own headers (node_api.h, uv.h).
set -euo pipefail
cd "$(dirname "$0")"

NODE="$(command -v node || true)"
[ -n "$NODE" ] || NODE=/usr/local/bin/node
NODE_ROOT="$(dirname "$(dirname "$(readlink -f "$NODE")")")"
NODE_INC="$NODE_ROOT/include/node"
[ -f "$NODE_INC/node_api.h" ] || { echo "Node headers not found in $NODE_INC (run install.sh first)"; exit 1; }

mkdir -p build
gcc -O2 -fPIC -fomit-frame-pointer -funroll-loops -W -Wall -c addon/vendor/crypt_blowfish.c -o build/crypt_blowfish.o

PQ_CFLAGS="$(pkg-config --cflags libpq)"
PQ_LIBS="$(pkg-config --libs libpq)"
# shellcheck disable=SC2086
g++ -std=c++20 -O2 -fPIC -shared -fvisibility=hidden -Wall \
  -Iaddon -I"$NODE_INC" $PQ_CFLAGS \
  addon/addon.cc build/crypt_blowfish.o \
  -o build/conduit.node $PQ_LIBS -lcrypto -lpthread

echo "built build/conduit.node (node $("$NODE" --version), libpq $(pkg-config --modversion libpq))"
