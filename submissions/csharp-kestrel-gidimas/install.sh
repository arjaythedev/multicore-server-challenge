#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04 box. Installs the pinned .NET SDK (see global.json).
set -euo pipefail
DOTNET_VERSION=10.0.300
INSTALL_DIR=/opt/dotnet

apt-get update -qq
apt-get install -y -qq curl ca-certificates

curl -sSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
bash /tmp/dotnet-install.sh --version "$DOTNET_VERSION" --install-dir "$INSTALL_DIR"
ln -sf "$INSTALL_DIR/dotnet" /usr/local/bin/dotnet
rm -f /tmp/dotnet-install.sh

dotnet --version | grep -qx "$DOTNET_VERSION"
