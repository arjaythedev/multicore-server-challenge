#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: a C compiler and the libraries nginx and the module link:
# PCRE2 and zlib (nginx), libpq (Postgres), libxcrypt (bcrypt). nginx itself is built from source by build.sh.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl build-essential libpcre2-dev zlib1g-dev libpq-dev libcrypt-dev
