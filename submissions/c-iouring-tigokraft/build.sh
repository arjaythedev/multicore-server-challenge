#!/usr/bin/env bash
# Builds bin/conduit as a normal user. One compiler call, no build system, no downloads.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p bin
CC="${CC:-gcc}"
"$CC" -std=gnu11 -O2 -march=native -pthread -Wall -Wextra -Wno-unused-parameter \
  -o bin/conduit src/*.c -luring -lcrypt -lm
echo "built bin/conduit ($("$CC" --version | head -1))"
