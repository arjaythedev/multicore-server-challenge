#!/usr/bin/env bash
# Native development install only. No sudo, package manager or automatic service.
set -euo pipefail
source "$(dirname "$0")/env.sh"
if [ "$(uname -s)" != Darwin ]; then echo 'This helper is for native macOS development.' >&2; exit 1; fi
if [ -x "$PGROOT/bin/pg_ctl" ]; then "$PGROOT/bin/postgres" --version; exit 0; fi
mkdir -p "$CHALLENGE_WORK/downloads" "$CHALLENGE_WORK/build/postgres-native"
archive="$CHALLENGE_WORK/downloads/postgresql-18.6.tar.bz2"
if [ ! -f "$archive" ]; then curl -fsSL https://ftp.postgresql.org/pub/source/v18.6/postgresql-18.6.tar.bz2 -o "$archive"; fi
echo "555610c24d53e4316da5b7d3fc25c279d96856d5e0e23ee308c328c5fa881d9f  $archive" | shasum -a 256 -c -
if [ ! -d "$CHALLENGE_WORK/build/postgresql-18.6" ]; then tar -xjf "$archive" -C "$CHALLENGE_WORK/build"; fi
cd "$CHALLENGE_WORK/build/postgres-native"
# ICU/readline/archive compression are unnecessary for this dedicated test cluster.
../postgresql-18.6/configure --prefix="$PGROOT" --without-icu --without-readline --without-zlib > "$CHALLENGE_WORK/logs/postgres-configure.log" 2>&1
make -j4 > "$CHALLENGE_WORK/logs/postgres-build.log" 2>&1
make install > "$CHALLENGE_WORK/logs/postgres-install.log" 2>&1
"$PGROOT/bin/postgres" --version
