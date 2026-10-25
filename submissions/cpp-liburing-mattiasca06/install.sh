#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: C++ toolchain, liburing and libpq headers from the archive.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q build-essential curl ca-certificates liburing-dev libpq-dev libssl-dev libcrypt-dev
g++ --version | head -1
dpkg-query -W liburing-dev libpq-dev libssl-dev libcrypt-dev
