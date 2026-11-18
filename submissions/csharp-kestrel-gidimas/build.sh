#!/usr/bin/env bash
# Runs as a normal user. Restores the locked package set and publishes a framework-dependent build to ./publish.
set -euo pipefail
cd "$(dirname "$0")"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1

dotnet restore src/Conduit.csproj --locked-mode
dotnet publish src/Conduit.csproj -c Release --no-restore -o publish
