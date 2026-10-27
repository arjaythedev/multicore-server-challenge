#!/usr/bin/env bash
# Builds the release as a normal user -> _build/prod/rel/conduit. Dependencies are pinned by mix.lock (hash-checked).
set -euo pipefail
cd "$(dirname "$0")"
export MIX_ENV=prod LANG=C.UTF-8
mix local.hex --force --if-missing
mix local.rebar --force --if-missing
mix deps.get --only prod
mix release conduit --overwrite
