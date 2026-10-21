#!/usr/bin/env bash
# Runs once as root on Ubuntu 24.04: installs a pinned Bun release system-wide.
set -euo pipefail

BUN_VERSION=1.4.3
apt-get update -q && apt-get install -y -q curl unzip ca-certificates
curl -fsSL https://bun.com/install \
  | env BUN_INSTALL=/usr/local bash -s -- "bun-v$BUN_VERSION"

/usr/local/bin/bun --version