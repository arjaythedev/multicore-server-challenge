#!/usr/bin/env bash
# Toolchain and libraries from Ubuntu 24.04's apt (libpq from the PGDG repo when the box has it).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q build-essential cmake git pkg-config ca-certificates \
  libpq-dev libjsoncpp-dev uuid-dev zlib1g-dev libssl-dev libjemalloc-dev
