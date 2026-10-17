#!/usr/bin/env bash
# Builds the server as a normal user -> bin/Conduit.dll. NuGet packages are restored in locked mode (packages.lock.json).
set -euo pipefail
cd "$(dirname "$0")"
DOTNET=/opt/dotnet/dotnet
[ -x "$DOTNET" ] || DOTNET=dotnet   # local development: dotnet on PATH
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
export DOTNET_SKIP_WORKLOAD_INTEGRITY_CHECK=1 DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE=1
# Run via runuser from a root login, the environment still names root's /run/user/0, which the build user cannot open: the SDK's NuGet
# migration mutex then fails with EACCES. Without it .NET falls back to /tmp.
unset XDG_RUNTIME_DIR
rm -rf bin obj
"$DOTNET" publish Conduit.csproj -c Release -o bin -p:RestoreLockedMode=true --nologo -v quiet
ls -l bin/Conduit.dll
