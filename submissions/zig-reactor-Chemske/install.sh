#!/usr/bin/env bash
# Official benchmark installation only; native Mac tools use dev/setup-postgres.sh.
set -euo pipefail
if [ "$(uname -s)" != Linux ] || [ "$(uname -m)" != x86_64 ]; then
    echo 'This installer targets Ubuntu 24.04 x86_64. Use the native development instructions on macOS.' >&2
    exit 1
fi
if [ "$EUID" -ne 0 ]; then echo 'Run install.sh as root on the benchmark host.' >&2; exit 1; fi
source /etc/os-release
if [ "$ID" != ubuntu ] || [ "$VERSION_ID" != 24.04 ]; then echo 'Ubuntu 24.04 is required.' >&2; exit 1; fi

tools=/opt/conduit-zig-tools
zig_prefix="$tools/zig-0.17.0"
pg_prefix="$tools/postgresql-18.6"
if [ -x "$zig_prefix/zig" ] && [ -f "$pg_prefix/lib/libpq.so" ] &&
   [ "$(cat "$pg_prefix/source-version" 2>/dev/null || true)" = 18.6 ] &&
   [ "$("$zig_prefix/zig" version)" = 0.17.0 ]; then
    echo 'Pinned Zig and libpq are already installed.'
    exit 0
fi
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl xz-utils bzip2 build-essential bison flex perl libssl-dev pkg-config
mkdir -p "$tools"
stage="$(mktemp -d "$tools/.install.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

if [ ! -x "$zig_prefix/zig" ]; then
    curl --proto '=https' --tlsv1.2 -fL https://ziglang.org/download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz -o "$stage/zig.tar.xz"
    echo "1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026  $stage/zig.tar.xz" | sha256sum -c -
    tar -xJf "$stage/zig.tar.xz" -C "$stage"
    mv "$stage/zig-x86_64-linux-0.17.0" "$zig_prefix"
fi
if [ ! -f "$pg_prefix/lib/libpq.so" ] || [ "$(cat "$pg_prefix/source-version" 2>/dev/null || true)" != 18.6 ]; then
    curl --proto '=https' --tlsv1.2 -fL https://ftp.postgresql.org/pub/source/v18.6/postgresql-18.6.tar.bz2 -o "$stage/postgres.tar.bz2"
    echo "555610c24d53e4316da5b7d3fc25c279d96856d5e0e23ee308c328c5fa881d9f  $stage/postgres.tar.bz2" | sha256sum -c -
    tar -xjf "$stage/postgres.tar.bz2" -C "$stage"
    cd "$stage/postgresql-18.6"
    ./configure --prefix="$pg_prefix" --without-icu --without-readline --without-zlib --without-libcurl --with-ssl=openssl
    # Build/install the client library and its support code, never another server.
    make -j2 -C src/interfaces/libpq
    make -C src/interfaces/libpq install
    echo 18.6 > "$pg_prefix/source-version"
fi
chmod -R a+rX "$zig_prefix" "$pg_prefix"
"$zig_prefix/zig" version
test "$("$zig_prefix/zig" version)" = 0.17.0
echo 'Installed source-built libpq 18.6; the provided PostgreSQL server is unchanged.'
