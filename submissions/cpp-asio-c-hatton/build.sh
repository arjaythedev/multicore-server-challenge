#!/usr/bin/env bash
# Builds bin/conduit. Built on the box itself, so it targets the box's CPU (-march=native).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p bin
CXX="${CXX:-$(command -v g++-13 || command -v g++)}"
"$CXX" -std=c++20 -O3 -march=native -flto="$(nproc)" -fno-plt -DNDEBUG -DBOOST_ASIO_NO_DEPRECATED \
  -Wall -Wextra -Wno-unused-parameter -I"$(pg_config --includedir 2>/dev/null || echo /usr/include/postgresql)" \
  src/main.cpp src/bcrypt_tables.cpp -o bin/conduit -lpq -lcrypt -lcrypto -pthread
echo "built bin/conduit"
