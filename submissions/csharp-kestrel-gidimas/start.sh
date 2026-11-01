#!/usr/bin/env bash
# Runs the server in the foreground. Configured only by the environment: DATABASE_URL, JWT_SECRET, HOST, PORT.
set -euo pipefail
# Run from the publish folder: it is the content root, where appsettings.json (log levels) is read from.
cd "$(dirname "$0")/publish"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
ulimit -n 200000 2>/dev/null || true
exec dotnet Conduit.dll
