#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: Go 1.27.3 from the official tarball (sha256 pinned) -> /usr/local/go.
set -euo pipefail
GO_VERSION=1.27.3
GO_SHA256=65efbc80fdc1fa2cd2631cad5b481777a68e8725f34e89f50fc6ac714e379b40
apt-get update -q && apt-get install -y -q curl ca-certificates
curl -fsSLo /tmp/go.tgz "https://go.dev/dl/go$GO_VERSION.linux-amd64.tar.gz"
echo "$GO_SHA256  /tmp/go.tgz" | sha256sum -c -
rm -rf /usr/local/go
tar -C /usr/local -xzf /tmp/go.tgz
rm /tmp/go.tgz
/usr/local/go/bin/go version
