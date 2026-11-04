#!/usr/bin/env bash
# Installs GCC, liburing, and libxcrypt for the B entrypoint and C support runtime.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q build-essential liburing-dev libcrypt-dev
cc --version | head -1
