#!/usr/bin/env bash
# Builds bin/conduit as a normal user. Downloads pinned third-party sources into third_party/ (SHA-256 checked).
set -euo pipefail
cd "$(dirname "$0")"

PICO_COMMIT=465a7ff09fbd3432fe56c673451f5460154d1f07
PICO_C_SHA=6480689711996bc9a219e26df27ac32ebbb7dce2f24a63a316d041b08f646199
PICO_H_SHA=1fc9074dd12418b2b91e55ef3a8279bccf8d3577b790dea6f2f908ab2a157f1c
YYJSON_TAG=0.10.0
YYJSON_C_SHA=98489c068ab65298320710e5be4c1090af1b5676e41301a3525b2e732641aace
YYJSON_H_SHA=adce02aef5dfd868f7c0b632bd23bc0e79fa710b70d93bfe334c2bd15b21a41d

fetch() { # dir file sha256 url
  local f="third_party/$1/$2"
  if [ -f "$f" ] && echo "$3  $f" | sha256sum -c --quiet 2>/dev/null; then return; fi
  mkdir -p "third_party/$1"
  curl -fsSL --retry 3 -o "$f" "$4"
  echo "$3  $f" | sha256sum -c --quiet
}
PICO_URL="https://raw.githubusercontent.com/h2o/picohttpparser/$PICO_COMMIT"
YY_URL="https://raw.githubusercontent.com/ibireme/yyjson/$YYJSON_TAG/src"
fetch picohttpparser picohttpparser.c "$PICO_C_SHA" "$PICO_URL/picohttpparser.c"
fetch picohttpparser picohttpparser.h "$PICO_H_SHA" "$PICO_URL/picohttpparser.h"
fetch yyjson yyjson.c "$YYJSON_C_SHA" "$YY_URL/yyjson.c"
fetch yyjson yyjson.h "$YYJSON_H_SHA" "$YY_URL/yyjson.h"

# mimalloc replaces malloc/free for the whole process (libpq included); ~3% less app CPU/request. USE_MIMALLOC=0 builds without it.
MI_VER=2.1.7
MI_SHA=0eed39319f139afde8515010ff59baf24de9e47ea316a315398e8027d198202d
MI_OBJ=; MI_DEF=
if [ "${USE_MIMALLOC:-1}" = 1 ]; then
  if [ ! -f third_party/mimalloc/src/static.c ]; then
    mkdir -p third_party/mimalloc
    curl -fsSL --retry 3 -o third_party/mimalloc.tgz "https://github.com/microsoft/mimalloc/archive/refs/tags/v$MI_VER.tar.gz"
    echo "$MI_SHA  third_party/mimalloc.tgz" | sha256sum -c --quiet
    tar -xzf third_party/mimalloc.tgz -C third_party/mimalloc --strip-components=1
    rm -f third_party/mimalloc.tgz
  fi
  MI_OBJ=build/mimalloc.o; MI_DEF="-DUSE_MIMALLOC -Ithird_party/mimalloc/include"
fi

mkdir -p bin build
CC="${CC:-gcc}"; CXX="${CXX:-g++}"
"$CC" -std=gnu11 -O3 -march=native -flto -c -o build/picohttpparser.o third_party/picohttpparser/picohttpparser.c
"$CC" -std=gnu11 -O3 -march=native -flto -c -o build/yyjson.o third_party/yyjson/yyjson.c
[ -n "$MI_OBJ" ] && "$CC" -std=gnu11 -O3 -march=native -DNDEBUG -DMI_MALLOC_OVERRIDE -Ithird_party/mimalloc/include -c -o build/mimalloc.o third_party/mimalloc/src/static.c
"$CXX" -std=c++20 -O3 -march=native -flto -pthread -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations \
  -Ithird_party/picohttpparser -Ithird_party/yyjson $MI_DEF -I"$(pg_config --includedir 2>/dev/null || echo /usr/include/postgresql)" \
  -o bin/conduit src/*.cpp build/picohttpparser.o build/yyjson.o $MI_OBJ -luring -lpq -lcrypto -lcrypt
echo "built bin/conduit ($("$CXX" --version | head -1))"
