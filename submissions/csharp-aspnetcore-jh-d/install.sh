#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: .NET SDK 10.0.402 (runtime 10.0.13), the official tarball, sha512-checked -> /opt/dotnet.
set -euo pipefail
DOTNET_SDK=10.0.402
SHA512=1904a98dda2db34ba78ba3c4fb1b224455329af91c341d83547843c1839e112b04ae699ee92fa2449a8f62249196a938723078c0c60b9f65c88539d5687729c2
apt-get update -q && apt-get install -y -q curl ca-certificates tar libssl3t64 libstdc++6 zlib1g
curl -fsSLo /tmp/dotnet-sdk.tgz "https://builds.dotnet.microsoft.com/dotnet/Sdk/$DOTNET_SDK/dotnet-sdk-$DOTNET_SDK-linux-x64.tar.gz"
echo "$SHA512  /tmp/dotnet-sdk.tgz" | sha512sum -c -
rm -rf /opt/dotnet && mkdir -p /opt/dotnet && tar -C /opt/dotnet -xzf /tmp/dotnet-sdk.tgz && rm /tmp/dotnet-sdk.tgz
chmod -R a+rX /opt/dotnet
DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 DOTNET_CLI_TELEMETRY_OPTOUT=1 /opt/dotnet/dotnet --version
