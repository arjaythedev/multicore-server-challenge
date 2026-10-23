#!/bin/sh
# Runs once as root on a clean Ubuntu 24.04.
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q build-essential liburing-dev libcrypt-dev
echo "--- toolchain ---"
gcc --version | head -1
dpkg-query -W liburing-dev libcrypt-dev
