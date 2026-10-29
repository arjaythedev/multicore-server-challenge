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
# packages.lock.json holds the hashes of the packages from nuget.org, as restored with the SDK that install.sh pins. Other
# SDKs (for example a distro's source-built one, which carries its own copy of the AOT packs) get other hashes, so
# with those the restore writes its lock file under obj/ and leaves the committed one alone, instead of failing on it.
if [ "$("$DOTNET" --version)" = "10.0.402" ]; then LOCK=(--locked-mode); else LOCK=("-p:NuGetLockFilePath=$PWD/obj/local.packages.lock.json"); fi
"$DOTNET" restore Conduit.csproj "${LOCK[@]}" -v quiet
"$DOTNET" publish Conduit.csproj -c Release -o bin --no-restore -v quiet -nologo ${EXTRA[@]+"${EXTRA[@]}"}
echo "built bin/conduit (.NET SDK $("$DOTNET" --version), Native AOT)"
