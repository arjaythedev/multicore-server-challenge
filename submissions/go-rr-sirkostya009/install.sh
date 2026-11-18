#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: Go 1.27.2 (official tarball, sha256-checked) -> /usr/local/go.
set -euo pipefail
GO_VERSION=1.27.2
apt-get update -q && apt-get install -y -q curl jq ca-certificates
SHA="$(curl -fsSL 'https://go.dev/dl/?mode=json&include=all' | jq -r --arg v "go$GO_VERSION" \
  '.[] | select(.version==$v) | .files[] | select(.os=="linux" and .arch=="amd64" and .kind=="archive") | .sha256')"
curl -fsSLo /tmp/go.tgz "https://go.dev/dl/go$GO_VERSION.linux-amd64.tar.gz"
echo "$SHA  /tmp/go.tgz" | sha256sum -c -
rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tgz && rm /tmp/go.tgz
/usr/local/go/bin/go version
