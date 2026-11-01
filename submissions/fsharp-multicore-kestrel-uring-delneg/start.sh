#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT (SPEC.md); knobs in README.md.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -x /usr/local/dotnet/dotnet ]; then export DOTNET_ROOT=/usr/local/dotnet; fi
export DOTNET_TieredPGO=1
exec "$HERE/out/Server"
