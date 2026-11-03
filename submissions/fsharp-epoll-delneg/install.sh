#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: the .NET 11 RC 3 SDK from Microsoft's official tarball (pinned,
# SHA-512 checked, from release-metadata/11.0/releases.json) into /usr/local/dotnet, plus libicu (the SDK's build
# tools need it) and gcc (build.sh compiles the bcrypt core from source).
set -euo pipefail
SDK=11.0.100-rc.3.26522.148
SHA512=77ef603622f0632ce59fc631871c9d0ec0c7402399837c659ead5b6fc7ea898f7f64a2632ecdc8d3330e608307416a36bff90a4d10179210489676167b9b80da
DEST=/usr/local/dotnet
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q --no-install-recommends ca-certificates curl gcc libc6-dev libicu74 libssl3t64 zlib1g
if [ -x "$DEST/dotnet" ] && "$DEST/dotnet" --list-sdks | grep -q "^$SDK "; then echo ".NET SDK $SDK already installed"; exit 0; fi
TMP="$(mktemp -d)"
curl -fsSL -o "$TMP/sdk.tar.gz" "https://builds.dotnet.microsoft.com/dotnet/Sdk/$SDK/dotnet-sdk-$SDK-linux-x64.tar.gz"
echo "$SHA512  $TMP/sdk.tar.gz" | sha512sum -c -
rm -rf "$DEST"
mkdir -p "$DEST"
tar -xzf "$TMP/sdk.tar.gz" -C "$DEST"
rm -rf "$TMP"
"$DEST/dotnet" --list-sdks
