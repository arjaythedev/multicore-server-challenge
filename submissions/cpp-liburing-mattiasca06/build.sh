#!/usr/bin/env bash
# Builds bin/conduit as a normal user. Downloads pinned third-party sources into third_party/ (SHA-256 checked).
set -euo pipefail
cd "$(dirname "$0")"

PICO_COMMIT=465a7ff09fbd3432fe56c673451f5460154d1f07
PICO_C_SHA=6480689711996bc9a219e26df27ac32ebbb7dce2f24a63a316d041b08f646199
PICO_H_SHA=1fc9074dd12418b2b91e55ef3a8279bccf8d3577b790dea6f2f908ab2a157f1c

fetch() { # name sha256
  local f="third_party/picohttpparser/$1"
  if [ -f "$f" ] && echo "$2  $f" | sha256sum -c --quiet 2>/dev/null; then return; fi
  mkdir -p third_party/picohttpparser
  curl -fsSL --retry 3 -o "$f" "https://raw.githubusercontent.com/h2o/picohttpparser/$PICO_COMMIT/$1"
  echo "$2  $f" | sha256sum -c --quiet
}
fetch picohttpparser.c "$PICO_C_SHA"
fetch picohttpparser.h "$PICO_H_SHA"

mkdir -p bin build
CC="${CC:-gcc}"; CXX="${CXX:-g++}"
"$CC" -std=gnu11 -O3 -march=native -flto -c -o build/picohttpparser.o third_party/picohttpparser/picohttpparser.c
"$CXX" -std=c++20 -O3 -march=native -flto -pthread -Wall -Wextra -Wno-unused-parameter \
  -Ithird_party/picohttpparser -I"$(pg_config --includedir 2>/dev/null || echo /usr/include/postgresql)" \
  -o bin/conduit src/*.cpp build/picohttpparser.o -luring -lpq
echo "built bin/conduit ($("$CXX" --version | head -1))"
