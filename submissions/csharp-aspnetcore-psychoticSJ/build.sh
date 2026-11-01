#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
if [ -x /opt/conduit-dotnet/dotnet ]; then
    export DOTNET_ROOT=/opt/conduit-dotnet
    export PATH="$DOTNET_ROOT:$PATH"
fi
export DOTNET_CLI_TELEMETRY_OPTOUT=1
dotnet restore ConduitChallenge.csproj --locked-mode
dotnet publish ConduitChallenge.csproj --no-restore -c Release --self-contained false -o publish
