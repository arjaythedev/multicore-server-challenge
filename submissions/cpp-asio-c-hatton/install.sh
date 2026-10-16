#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: the C++ toolchain and libraries, all from the Ubuntu 24.04
# archive (libpq-dev from PGDG if the box has that repo, as the benchmark box does; any libpq >= 14 works).
#   g++ 13, Boost 1.83 headers (Asio, JSON), libpq (pipeline mode), OpenSSL 3 (SHA-256), libxcrypt (bcrypt fallback)
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q --no-install-recommends g++-13 libboost1.83-dev libpq-dev libssl-dev libcrypt-dev ca-certificates
