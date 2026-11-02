#!/usr/bin/env bash
# Builds bin/conduit from source with the system compiler. No dependencies beyond libc.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p bin
MARCH=-march=native
[ "$(uname -m)" = x86_64 ] || MARCH=
gcc -std=gnu11 -D_GNU_SOURCE -O3 $MARCH -flto -fno-plt -fno-semantic-interposition -Wall -Wextra -Wno-unused-parameter \
  -pthread -o bin/conduit src/*.c
