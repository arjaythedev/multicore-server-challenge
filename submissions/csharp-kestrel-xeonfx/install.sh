#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: .NET SDK 10.0.402 (official tarball, sha512-checked) -> /usr/local/dotnet.
set -euo pipefail
SDK_VERSION=10.0.402
case "$(uname -m)" in x86_64) RID=linux-x64 ;; aarch64) RID=linux-arm64 ;; *) echo "unsupported arch $(uname -m)"; exit 1 ;; esac
apt-get update -q && apt-get install -y -q curl jq ca-certificates libstdc++6
FILE="$(curl -fsSL "https://builds.dotnet.microsoft.com/dotnet/release-metadata/${SDK_VERSION%.*}/releases.json" \
  | jq -c --arg v "$SDK_VERSION" --arg rid "$RID" \
    '[.releases[].sdks[]? | select(.version == $v) | .files[] | select(.rid == $rid and (.name | endswith(".tar.gz")))][0]')"
URL="$(jq -r .url <<<"$FILE")"; SHA="$(jq -r .hash <<<"$FILE")"
[ -n "$URL" ] && [ "$URL" != null ] || { echo "no .NET SDK $SDK_VERSION for $RID in the release metadata"; exit 1; }
curl -fsSLo /tmp/dotnet.tgz "$URL"
echo "$SHA  /tmp/dotnet.tgz" | sha512sum -c -
rm -rf /usr/local/dotnet && mkdir -p /usr/local/dotnet && tar -C /usr/local/dotnet -xzf /tmp/dotnet.tgz && rm /tmp/dotnet.tgz
chmod -R a+rX /usr/local/dotnet
DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 /usr/local/dotnet/dotnet --version
