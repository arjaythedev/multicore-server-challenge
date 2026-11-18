#!/usr/bin/env bash
# No npm dependencies (Bun.serve and Bun.SQL are built in). Builds the bcrypt library loaded through bun:ffi
# (Openwall's public-domain core + a lane-interleaved driver, native/) and runs its self-test, then Bun's type check
# for the ahead-of-time compiler and `bun compile` of the server into one executable (the bcrypt thread with it).
set -euo pipefail
cd "$(dirname "$0")"
BUN="${BUN:-/opt/bun-v1.4.4-canary.20261031.1/bin/bun}"
mkdir -p bin
ARCH_FLAGS="-march=native"
[ "$(uname -s)" = Darwin ] && ARCH_FLAGS="-mcpu=native"
cc -std=gnu11 -O3 $ARCH_FLAGS -fPIC -shared -DNDEBUG -I native native/bcrypt.c -o bin/libbcrypt.so
"$BUN" -e "const {dlopen}=require('bun:ffi');const l=dlopen('./bin/libbcrypt.so',{bc_selftest:{args:[],returns:'i32'}});if(!l.symbols.bc_selftest())process.exit(1)"
"$BUN" check --aot src/server.ts
"$BUN" compile src/server.ts --outfile server
echo "build ok"
