#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: Go 1.27.2 from the official tarball (sha256 pinned) -> /usr/local/go.
set -euo pipefail
GO_VERSION=1.27.2
GO_SHA256=ecbadb99091a3f46e31f5f934b068b1864eafa7995211b39eaddf76996045fe5
# curl and the CA bundle are only fetched when missing. The packages are pinned to the Ubuntu 24.04 versions this was
# built with; if the archive no longer carries them, the current ones are used (the Go tarball is sha256-checked
# either way, so the transport is not trusted for its contents).
CURL_VERSION=8.5.0-2ubuntu10.16
CA_CERTIFICATES_VERSION=20260816ubuntu0.24.04.1
if ! command -v curl >/dev/null || [ ! -e /etc/ssl/certs/ca-certificates.crt ]; then
  apt-get update -q
  apt-get install -y -q "curl=$CURL_VERSION" "ca-certificates=$CA_CERTIFICATES_VERSION" ||
    apt-get install -y -q curl ca-certificates
fi
if [ "$(/usr/local/go/bin/go env GOVERSION 2>/dev/null || true)" != "go$GO_VERSION" ]; then
  curl -fsSLo /tmp/go.tgz "https://go.dev/dl/go$GO_VERSION.linux-amd64.tar.gz"
  echo "$GO_SHA256  /tmp/go.tgz" | sha256sum -c -
  rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tgz && rm /tmp/go.tgz
fi
/usr/local/go/bin/go version
