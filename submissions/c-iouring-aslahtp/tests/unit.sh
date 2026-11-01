#!/usr/bin/env bash
# Builds and runs the unit tests (no network or database needed). Usage: bash tests/unit.sh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p bin
"${CC:-gcc}" -std=gnu11 -O2 -g -Wall -Wextra -Wno-unused-parameter -fsanitize=undefined ${SANITIZE:+-fsanitize=address} \
  -o bin/unit tests/unit.c src/arena.c src/base64.c src/bcrypt.c src/bcrypt_lanes.c src/buf.c src/hmac.c src/json_in.c \
  src/json_out.c src/jwt.c src/pg_wire.c src/sha256.c src/util.c
./bin/unit
