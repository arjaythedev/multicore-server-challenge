#!/usr/bin/env bash
# Builds the server with Native AOT -> bin/conduit (one native executable). Restores exactly packages.lock.json. Idempotent.
# Needs clang and zlib1g-dev (install.sh adds them); where clang is missing, the build falls back to gcc.
set -euo pipefail
cd "$(dirname "$0")"
export DOTNET_ROOT="${DOTNET_ROOT:-/usr/local/dotnet}" DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
DOTNET="$DOTNET_ROOT/dotnet"
[ -x "$DOTNET" ] || DOTNET=dotnet
EXTRA=()
command -v clang >/dev/null 2>&1 || EXTRA+=(-p:CppCompilerAndLinker=gcc)
rm -rf bin
"$DOTNET" restore Conduit.csproj --locked-mode -v quiet
"$DOTNET" publish Conduit.csproj -c Release -o bin --no-restore -v quiet -nologo ${EXTRA[@]+"${EXTRA[@]}"}
echo "built bin/conduit (.NET SDK $("$DOTNET" --version), Native AOT)"
