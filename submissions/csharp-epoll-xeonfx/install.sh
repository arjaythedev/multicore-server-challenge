#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: the .NET 10 SDK (pinned) in /usr/local/dotnet, and clang and zlib for
# the NativeAOT link (Ubuntu 24.04's own packages: clang 18).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl clang binutils zlib1g-dev
curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
bash /tmp/dotnet-install.sh --version 10.0.402 --install-dir /usr/local/dotnet
ln -sf /usr/local/dotnet/dotnet /usr/local/bin/dotnet
