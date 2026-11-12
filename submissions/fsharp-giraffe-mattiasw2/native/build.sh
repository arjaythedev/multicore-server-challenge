#!/usr/bin/env bash
# native/build.sh <path/libcbcrypt.so>: the bcrypt library from cbcrypt.c and, on x86-64, the assembly kernels
# that gen-bcrypt-x86.py writes. src/Engine/Engine.fsproj runs it, so every build, publish and test has the library
# beside its assemblies. Symbols stay in (perf attributes its samples); no -march: the assembly kernels are chosen
# at run time by what the CPU has.
set -euo pipefail
cd "$(dirname "$0")"
OUT="$1"
mkdir -p "$(dirname "$OUT")"
SOURCES=(cbcrypt.c)
if [ "$(uname -m)" = x86_64 ]; then
  python3 gen-bcrypt-x86.py > "${OUT%.so}.S"
  SOURCES+=("${OUT%.so}.S")
fi
gcc -std=gnu11 -O3 -g -fPIC -shared -fvisibility=hidden -Wall -Wextra -Werror -Wl,-z,noexecstack -o "$OUT" "${SOURCES[@]}"
