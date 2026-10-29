#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04 x86-64. Running it again is safe and quick.
# Installs the C toolchain (gcc builds the bcrypt library, clang links the Native AOT binary)
# and the pinned .NET SDK from Microsoft's tarball, checked against its published SHA-512.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "install.sh must run as root" >&2
  exit 1
fi
if [ "$(uname -m)" != x86_64 ]; then
  echo "install.sh supports x86-64 only, not $(uname -m)" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
# A freshly booted cloud image often holds the dpkg lock for its first unattended upgrade,
# so apt waits for the lock instead of failing at once.
apt_get() {
  apt-get -o DPkg::Lock::Timeout=600 -o Acquire::Retries=5 "$@"
}
apt_get update
# ICU lets the SDK start without invariant mode; the server's HMAC, SHA-256 and PBKDF2 come from OpenSSL.
apt_get install -y --no-install-recommends ca-certificates curl gcc libc6-dev clang binutils zlib1g-dev \
  libicu74 libssl3t64

# From https://builds.dotnet.microsoft.com/dotnet/release-metadata/10.0/releases.json (SDK 10.0.303, linux-x64).
SDK_VERSION=10.0.303
SDK_SHA512=538df11ceb9d86bdda061bab6ede3d1f6d46bb9ba087ae905643f3d456afe982949d1b952bceb305a5d22d2d6e69cc0e5100216ffcc709aaa86e867f2d9cdf9a
# A directory of its own, so an SDK already on the box (CI runners ship several) is left alone.
SDK_DIR=/usr/local/lib/dotnet-sdk-$SDK_VERSION
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1

if [ "$("$SDK_DIR/dotnet" --version 2>/dev/null || true)" != "$SDK_VERSION" ]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 -o "$tmp/sdk.tar.gz" \
    "https://builds.dotnet.microsoft.com/dotnet/Sdk/$SDK_VERSION/dotnet-sdk-$SDK_VERSION-linux-x64.tar.gz"
  echo "$SDK_SHA512  $tmp/sdk.tar.gz" | sha512sum -c --quiet -
  rm -rf "$SDK_DIR"
  mkdir -p "$SDK_DIR"
  tar -xzf "$tmp/sdk.tar.gz" -C "$SDK_DIR"
  chmod -R a+rX "$SDK_DIR"
fi

"$SDK_DIR/dotnet" --version
