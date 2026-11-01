#!/usr/bin/env bash
set -euo pipefail
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get install -y -q gcc make libc6-dev libpq-dev libssl-dev libcrypt-dev
cc --version && make --version | head -1
pkg-config --modversion libpq 2>/dev/null || dpkg -s libpq-dev | grep '^Version'
echo "install.sh done"
