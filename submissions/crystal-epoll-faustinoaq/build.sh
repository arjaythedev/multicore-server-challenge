#!/usr/bin/env bash
# Builds the server for this CPU. No shards: Crystal's stdlib plus libcrypto and libdeflate.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p bin
# -Dgc_none: no garbage collector at all. Buffers are allocated at start-up and grown with
# realloc; the request path creates no Crystal objects, so there is nothing to collect.
crystal build --release --no-debug -Dgc_none --mcpu x86-64-v3 src/main.cr -o bin/server
