#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: compiler and libraries from the Ubuntu 24.04 archive.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q build-essential g++-13 liburing-dev libssl-dev libcrypt-dev
g++-13 --version | head -1
dpkg-query -W g++-13 liburing-dev libssl-dev libcrypt-dev
