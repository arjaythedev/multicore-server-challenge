#!/usr/bin/env bash
# Builds the server as a normal user. NuGet packages are pinned (src/packages.lock.json, locked mode).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DOTNET="${DOTNET:-/usr/local/dotnet/dotnet}"
[ -x "$DOTNET" ] || DOTNET="$(command -v dotnet)"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
"$DOTNET" publish "$HERE/src/Conduit.csproj" -c Release -o "$HERE/out" -p:RestoreLockedMode=true -p:UseAppHost=true
