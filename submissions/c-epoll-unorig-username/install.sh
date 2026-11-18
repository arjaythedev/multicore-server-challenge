#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: the distribution's gcc (build-essential) is the whole toolchain.
set -euo pipefail
apt-get update -q
apt-get install -y -q build-essential
gcc --version | sed -n 1p
