#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: a C compiler and the libpq, OpenSSL and libxcrypt headers.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q --no-install-recommends gcc libc6-dev libpq-dev libssl-dev libcrypt-dev
gcc --version | head -1
