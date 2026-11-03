#!/usr/bin/env bash
# One-time setup as root on a clean Ubuntu 24.04.
#   - gcc and libc headers: build.sh compiles the bcrypt core (native/bcrypt.c)
#   - libicu74, libssl3t64, zlib1g: what the .NET SDK and runtime load
#   - the .NET SDK 11.0.100-rc.3.26522.148 into /usr/local/dotnet, from Microsoft's tarball; the SHA-512 is the one
#     listed for it in Microsoft's release metadata (dotnet/core release-metadata/11.0/releases.json)
set -euo pipefail

version=11.0.100-rc.3.26522.148
sha512=77ef603622f0632ce59fc631871c9d0ec0c7402399837c659ead5b6fc7ea898f7f64a2632ecdc8d3330e608307416a36bff90a4d10179210489676167b9b80da
url="https://builds.dotnet.microsoft.com/dotnet/Sdk/$version/dotnet-sdk-$version-linux-x64.tar.gz"
root=/usr/local/dotnet

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q --no-install-recommends ca-certificates curl gcc libc6-dev libicu74 libssl3t64 zlib1g

if [ -x "$root/dotnet" ] && "$root/dotnet" --list-sdks | grep -q "^$version "; then
  echo "SDK $version is already in $root"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
curl -fsSL --retry 3 -o "$work/sdk.tgz" "$url"
printf '%s  %s\n' "$sha512" "$work/sdk.tgz" | sha512sum --check --strict -
rm -rf "$root" && mkdir -p "$root"
tar -xzf "$work/sdk.tgz" -C "$root"
"$root/dotnet" --list-sdks
