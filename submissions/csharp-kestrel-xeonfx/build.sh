#!/usr/bin/env bash
# Builds the server -> bin/conduit.dll (Release, JIT with dynamic PGO). Restores exactly packages.lock.json. Idempotent.
set -euo pipefail
cd "$(dirname "$0")"
export DOTNET_ROOT="${DOTNET_ROOT:-/usr/local/dotnet}" DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
DOTNET="$DOTNET_ROOT/dotnet"
[ -x "$DOTNET" ] || DOTNET=dotnet
"$DOTNET" restore Conduit.csproj --locked-mode -v quiet
"$DOTNET" publish Conduit.csproj -c Release -o bin --no-restore -v quiet -nologo
echo "built bin/conduit.dll (.NET SDK $("$DOTNET" --version))"
