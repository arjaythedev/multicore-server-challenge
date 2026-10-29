#!/usr/bin/env bash
# Runs as a normal user, possibly under `env -i`, so it sets everything it needs.
# Builds the native bcrypt library, then publishes the Native AOT server to out/.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"

DOTNET=/usr/local/lib/dotnet-sdk-10.0.303/dotnet
if [ ! -x "$DOTNET" ]; then
  echo "build.sh: $DOTNET not found; run install.sh as root first" >&2
  exit 1
fi

export PATH=/usr/local/bin:/usr/bin:/bin
# The SDK writes its caches under HOME; keep them inside the folder, which the build user owns.
export HOME="$ROOT/obj/home"
export DOTNET_CLI_HOME="$ROOT/obj/dotnet-home"
export NUGET_PACKAGES="$ROOT/obj/nuget"
export DOTNET_NOLOGO=1 DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
# The build uses no SDK workloads; the first-run workload check only printed a false alarm on a fresh install.
export DOTNET_SKIP_WORKLOAD_INTEGRITY_CHECK=1
mkdir -p "$HOME" "$DOTNET_CLI_HOME" "$NUGET_PACKAGES"

bash native/build-native.sh
"$DOTNET" publish src/Conduit.csproj -c Release -o out
