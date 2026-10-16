#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: a C compiler, liburing (io_uring) and libxcrypt (bcrypt) headers,
# all from the Ubuntu 24.04 archive (liburing-dev 2.5, libcrypt-dev 4.4.36).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q build-essential liburing-dev libcrypt-dev
gcc --version | head -1
dpkg-query -W liburing-dev libcrypt-dev
