#!/usr/bin/env bash
# Builds bin/conduit as a normal user: one compiler invocation, no downloads.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p bin
CXX="${CXX:-g++-13}"
command -v "$CXX" >/dev/null || CXX=g++
"$CXX" -std=c++20 -O3 -march=native -mprefer-vector-width=256 -flto=auto -fno-plt -fno-semantic-interposition \
  -DNDEBUG -pthread -Wall -Wextra -Wno-unused-parameter \
  -o bin/conduit src/*.cpp -luring -lcrypto -lcrypt
echo "built bin/conduit ($("$CXX" --version | head -1))"
