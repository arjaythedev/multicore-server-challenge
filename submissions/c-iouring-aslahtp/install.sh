#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: a C compiler and liburing (io_uring), both from the Ubuntu 24.04
# archive (gcc 13.3, liburing-dev 2.5). Everything else (crypto, JSON, the Postgres client) is in src/.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q build-essential liburing-dev
gcc --version | head -1
dpkg-query -W liburing-dev
