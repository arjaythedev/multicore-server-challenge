#!/usr/bin/env bash
set -euo pipefail
SDK_VERSION=10.0.402
SDK_HASH=1904a98dda2db34ba78ba3c4fb1b224455329af91c341d83547843c1839e112b04ae699ee92fa2449a8f62249196a938723078c0c60b9f65c88539d5687729c2
SDK_ROOT=/opt/conduit-dotnet
apt-get update -qq
apt-get install -y -qq ca-certificates curl libc6 libgcc-s1 libgssapi-krb5-2 libicu74 libssl3t64 libstdc++6 zlib1g
if [ ! -x "$SDK_ROOT/dotnet" ] || ! "$SDK_ROOT/dotnet" --list-sdks | grep -q "^$SDK_VERSION "; then
    archive=$(mktemp)
    trap 'rm -f "$archive"' EXIT
    curl -fsSL "https://builds.dotnet.microsoft.com/dotnet/Sdk/$SDK_VERSION/dotnet-sdk-$SDK_VERSION-linux-x64.tar.gz" -o "$archive"
    printf '%s  %s\n' "$SDK_HASH" "$archive" | sha512sum -c -
    mkdir -p "$SDK_ROOT"
    tar -xzf "$archive" -C "$SDK_ROOT"
fi
