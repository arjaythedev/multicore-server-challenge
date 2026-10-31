#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04. The server is pure assembly linked statically with no libc, so the
# only build dependency is GNU binutils (as, ld), which ships in binutils.
set -euo pipefail
apt-get update -q && apt-get install -y -q binutils
as --version | head -1
ld --version | head -1
