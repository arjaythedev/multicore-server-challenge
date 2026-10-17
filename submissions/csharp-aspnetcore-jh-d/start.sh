#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT (everything else is set here).
set -euo pipefail
cd "$(dirname "$0")"
DOTNET=/opt/dotnet/dotnet
[ -x "$DOTNET" ] || DOTNET=dotnet   # local development: dotnet on PATH
export DOTNET_ROOT="${DOTNET_ROOT:-/opt/dotnet}"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
export DOTNET_EnableDiagnostics=0
exec "$DOTNET" bin/Conduit.dll
