#!/usr/bin/env bash
# Builds the release as a normal user -> _build/prod/rel/conduit. Dependencies are pinned by mix.lock (hash-checked).
set -euo pipefail
cd "$(dirname "$0")"
export MIX_ENV=prod LANG=C.UTF-8 HEX_HTTP_TIMEOUT=120
export CFLAGS="${CFLAGS:--g -O3 -fno-semantic-interposition -flto --param=max-inline-insns-auto=500 -fipa-pta}"
mix local.hex --force --if-missing
mix deps.get --only prod
mix deps.compile --force
mix release conduit --overwrite
