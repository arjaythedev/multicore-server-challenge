#!/usr/bin/env bash
# Builds bin/conduit as a normal user: one compiler call, no downloads. x86-64-v3 (AVX2/BMI2), not -march=native,
# so the binary never assumes more than the benchmark box's CPU has.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p bin
CC="${CC:-gcc}"
"$CC" -std=gnu11 -O3 -march=x86-64-v3 -pthread -Wall -Wextra -Wno-unused-parameter \
  -o bin/conduit src/*.c -luring
echo "built bin/conduit ($("$CC" --version | head -1))"
