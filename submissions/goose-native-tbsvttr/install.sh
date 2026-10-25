#!/usr/bin/env bash
# Ubuntu 24.04: build.sh compiles the pinned Goose source as a normal user.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q --no-install-recommends build-essential cmake curl ca-certificates libssl-dev
printf 'C compiler: '
gcc --version | head -1
