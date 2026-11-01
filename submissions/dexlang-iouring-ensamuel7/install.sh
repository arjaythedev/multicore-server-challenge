#!/usr/bin/env bash
set -euo pipefail

GO_VERSION=1.27.2
case "$(uname -m)" in
  x86_64|amd64)  GO_ARCH=amd64; GO_SHA256=ecbadb99091a3f46e31f5f934b068b1864eafa7995211b39eaddf76996045fe5 ;;
  aarch64|arm64) GO_ARCH=arm64; GO_SHA256=94f3e30b8e374bc285e7dadc11e0865726b9bc6e85b841ccceaabc0214c6b7c8 ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  build-essential \
  ca-certificates \
  curl \
  git \
  pkg-config \
  libpq-dev \
  libcrypt-dev \
  libsqlite3-dev \
  libssl-dev \
  libcurl4-openssl-dev

curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${GO_ARCH}.tar.gz" -o /tmp/go.tar.gz
echo "${GO_SHA256}  /tmp/go.tar.gz" | sha256sum -c -
rm -rf /usr/local/go
tar -C /usr/local -xzf /tmp/go.tar.gz
rm -f /tmp/go.tar.gz

/usr/local/go/bin/go version
cc --version | head -1
pkg-config --modversion libpq libxcrypt openssl
