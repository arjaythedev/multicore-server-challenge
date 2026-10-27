#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
if [ -x /opt/conduit-dotnet/dotnet ]; then
    export DOTNET_ROOT=/opt/conduit-dotnet
    export PATH="$DOTNET_ROOT:$PATH"
fi
export DOTNET_TieredPGO=1
export DOTNET_CLI_TELEMETRY_OPTOUT=1
exec dotnet publish/ConduitChallenge.dll
