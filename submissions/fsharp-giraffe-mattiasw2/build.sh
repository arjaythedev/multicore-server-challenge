#!/usr/bin/env bash
# Builds the server -> out/Web.dll (Release, JIT with tiered PGO). Restores exactly the packages.lock.json
# graphs (rule 11: pinned dependencies). Idempotent. The test project is not built here (see check.sh).
set -euo pipefail
cd "$(dirname "$0")"
export DOTNET_ROOT="${DOTNET_ROOT:-/usr/local/dotnet}" DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
DOTNET="$DOTNET_ROOT/dotnet"
[ -x "$DOTNET" ] || DOTNET=dotnet
"$DOTNET" restore src/Web/Web.fsproj --locked-mode -v quiet
"$DOTNET" publish src/Web/Web.fsproj -c Release -o out --no-restore -v quiet -nologo
echo "built out/Web.dll (.NET SDK $("$DOTNET" --version))"
