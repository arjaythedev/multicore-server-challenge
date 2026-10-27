#!/usr/bin/env bash
# Builds bin/conduit as a normal user with LTO and target-specific SIMD optimizations.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p bin
CC="${CC:-gcc}"
"$CC" -std=gnu11 -O3 -march=native -flto=auto -fno-plt -pthread \
  -Wall -Wextra -Wno-unused-parameter \
  -o bin/conduit src/*.c -luring -lcrypt -lm
echo "built bin/conduit ($("$CC" --version | head -1))"
