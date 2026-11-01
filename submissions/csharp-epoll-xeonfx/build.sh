#!/usr/bin/env bash
# Builds as a normal user: a NativeAOT binary, bin/app/conduit. CONDUIT_JIT=1 builds the JIT version, bin/app/conduit.dll.
set -euo pipefail
cd "$(dirname "$0")"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
# the SDK runs without ICU (a minimal Ubuntu has none); the app is built with InvariantGlobalization too
export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
rm -rf bin/app
if [ "${CONDUIT_JIT:-0}" = 1 ]; then
  dotnet publish Conduit.csproj -c Release -o bin/app -v q -nologo -p:PublishAot=false -p:UseAppHost=false
else
  case "$(uname -m)" in aarch64) rid=linux-arm64 ;; *) rid=linux-x64 ;; esac
  dotnet publish Conduit.csproj -c Release -r "$rid" -o bin/app -v q -nologo
fi
