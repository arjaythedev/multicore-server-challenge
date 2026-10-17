#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT
# (optional: DB_POOL_SIZE, default 4 per core; DB_MULTIPLEXING=0 turns Npgsql multiplexing off;
# BCRYPT_THREADS, default one per two cores, at least 1).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
export DOTNET_ROOT="${DOTNET_ROOT:-/usr/local/dotnet}" DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
# 64 MB gen0 budget per heap: each request allocates a few KB, and with the default budget server GC runs a
# gen0 collection many times a second. The runtime reads this setting only from the environment.
export DOTNET_GCgen0size="${DOTNET_GCgen0size:-0x4000000}"
DOTNET="$DOTNET_ROOT/dotnet"
[ -x "$DOTNET" ] || DOTNET=dotnet
exec "$DOTNET" "$DIR/bin/conduit.dll"
