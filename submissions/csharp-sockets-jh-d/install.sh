#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: the .NET 10 SDK from Microsoft's official tarball (pinned, checksummed)
# into /usr/local/dotnet. https://learn.microsoft.com/dotnet/core/install/linux-scripted-manual#manual-install
set -euo pipefail
SDK=10.0.402
SHA512=1904a98dda2db34ba78ba3c4fb1b224455329af91c341d83547843c1839e112b04ae699ee92fa2449a8f62249196a938723078c0c60b9f65c88539d5687729c2
DEST=/usr/local/dotnet
if [ -x "$DEST/dotnet" ] && "$DEST/dotnet" --list-sdks | grep -q "^$SDK "; then echo ".NET SDK $SDK already installed"; exit 0; fi
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q ca-certificates curl libc6 libgcc-s1 libstdc++6 zlib1g tzdata libssl3t64
TMP="$(mktemp -d)"
curl -fsSL -o "$TMP/sdk.tar.gz" "https://builds.dotnet.microsoft.com/dotnet/Sdk/$SDK/dotnet-sdk-$SDK-linux-x64.tar.gz"
echo "$SHA512  $TMP/sdk.tar.gz" | sha512sum -c -
rm -rf "$DEST"
mkdir -p "$DEST"
tar -xzf "$TMP/sdk.tar.gz" -C "$DEST"
rm -rf "$TMP"
"$DEST/dotnet" --list-sdks
