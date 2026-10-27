#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: installs GCC, liburing (io_uring) and libxcrypt (bcrypt)
# from the official Ubuntu 24.04 archive.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q build-essential liburing-dev libcrypt-dev
gcc --version | head -1
dpkg-query -W liburing-dev libcrypt-dev
