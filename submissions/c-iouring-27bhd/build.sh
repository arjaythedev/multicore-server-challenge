#!/usr/bin/env bash
# Builds the C server binary as a normal user -> bin/server.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p bin

CC="${CC:-gcc}"
CFLAGS="-O3 -march=native -mtune=native -flto -fno-plt -Wall"
if pkg-config --exists libpq 2>/dev/null; then
  PG_CFLAGS="$(pkg-config --cflags libpq)"
  PG_LIBS="$(pkg-config --libs libpq)"
else
  PG_CFLAGS="-I/usr/include/postgresql"
  PG_LIBS="-lpq"
fi

$CC $CFLAGS $PG_CFLAGS \
  src/main.c src/http_routes.c src/db_libpq.c src/auth_crypto.c src/bcrypt_pool.c \
  $PG_LIBS -lcrypt -lpthread -luring \
  -o bin/server
