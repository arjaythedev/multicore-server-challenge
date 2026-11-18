#!/usr/bin/env bash
# Builds as a normal user:
#  1. the bcrypt core and the io_uring ring code (native/bcrypt.c, native/uring.c, written for this entry) from source
#     into out/libconduitbc.so;
#  2. the server with dotnet publish (ReadyToRun, locked NuGet restore) into out/.
set -euo pipefail
cd "$(dirname "$0")"
DOTNET="${DOTNET:-/usr/local/dotnet/dotnet}"
[ -x "$DOTNET" ] || DOTNET="$(command -v dotnet)"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 MSBUILDDISABLENODEREUSE=1
mkdir -p out
gcc -O3 -funroll-loops -fPIC -shared -o out/libconduitbc.so native/bcrypt.c native/uring.c
(cd src && "$DOTNET" publish Server.fsproj -c Release --use-current-runtime --self-contained false -o ../out -p:RestoreLockedMode=true)
"$DOTNET" build-server shutdown > /dev/null 2>&1 || true
