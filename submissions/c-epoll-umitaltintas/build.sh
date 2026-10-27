#!/usr/bin/env bash
# Builds bin/conduit from src/*.c. Idempotent.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p bin
PGINC="$(pg_config --includedir 2>/dev/null || echo /usr/include/postgresql)"
gcc -std=gnu11 -O2 -march=native -pthread -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations \
  -I"$PGINC" -o bin/conduit src/*.c -lpq -lcrypto -lcrypt
echo "built bin/conduit"
