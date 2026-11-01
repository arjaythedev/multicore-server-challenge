#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04 x86_64: a C compiler and liburing
# (io_uring) + libxcrypt (bcrypt fallback) headers, all from the Ubuntu 24.04
# archive (liburing-dev 2.5, libcrypt-dev 4.4.36). No prebuilt binaries, no
# pip/cargo; apt-get install is inherently idempotent, and -q keeps it quiet.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -q
apt-get install -y -q build-essential liburing-dev libcrypt-dev

gcc --version | head -1
dpkg-query -W liburing-dev libcrypt-dev
