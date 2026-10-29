#!/usr/bin/env bash
# Builds libconduit_bcrypt.so from the vendored crypt_blowfish source.
set -euo pipefail
cd "$(dirname "$0")"
gcc -O2 -fPIC -shared -Wall -Wextra -o libconduit_bcrypt.so bcrypt_lanes.c
