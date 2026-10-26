#!/usr/bin/env bash
# Builds bin/conduit (ReleaseFast, LLVM, for x86-64-v3: a fixed level, not this machine's CPU, so the binary runs
# on any v3 CPU it lands on). Runs as a normal user with a clean PATH, so the toolchain is found by its install path;
# the Zig caches stay inside this folder.
# The bcrypt kernels (src/bcrypt/kernels.zig, plus the expand0 assembly asm_gen.zig writes) are built as their own
# objects; kernels_port.zig is the same Zig kernel for baseline x86-64. Now that the server itself is built for
# x86-64-v3, a CPU without v3 cannot run it, so that fallback no longer serves one.
# libdeflate (vendor/libdeflate, gzip compression only) is compiled freestanding: no libc, no stack protector. It
# picks its CRC kernel at run time and gets its memory from the server (src/gzip.zig).
set -euo pipefail
cd "$(dirname "$0")"
ZIG=/opt/zig-0.17.0/zig
[ -x "$ZIG" ] || ZIG=zig   # local development: zig on PATH
mkdir -p bin .zig-cache
CACHE=(--cache-dir .zig-cache --global-cache-dir .zig-cache/global)
V3=(-O ReleaseFast -fllvm -target x86_64-linux -mcpu=x86_64_v3+fast_bextr -fstrip)
"$ZIG" run src/bcrypt/asm_gen.zig "${CACHE[@]}" -- .zig-cache/expand0.S
"$ZIG" build-obj .zig-cache/expand0.S "${V3[@]}" --name bcrypt_expand0 -femit-bin=.zig-cache/bcrypt_expand0.o "${CACHE[@]}"
"$ZIG" build-obj src/bcrypt/kernels.zig "${V3[@]}" --name bcrypt_kernels -femit-bin=.zig-cache/bcrypt_kernels.o "${CACHE[@]}"
"$ZIG" build-obj src/bcrypt/kernels_port.zig -O ReleaseFast -fllvm -target x86_64-linux -mcpu=x86_64 -fstrip \
  --name bcrypt_port -femit-bin=.zig-cache/bcrypt_port.o "${CACHE[@]}"
LD=vendor/libdeflate/lib
"$ZIG" build-obj -O ReleaseFast -target x86_64-linux-none -mcpu=x86_64_v3 -fstrip \
  -cflags -std=c99 -ffreestanding -DFREESTANDING -fno-stack-protector -- \
  "$LD"/deflate_compress.c "$LD"/gzip_compress.c "$LD"/crc32.c "$LD"/utils.c "$LD"/x86/cpu_features.c \
  --name libdeflate -femit-bin=.zig-cache/libdeflate.o "${CACHE[@]}"
"$ZIG" build-exe src/main.zig .zig-cache/bcrypt_kernels.o .zig-cache/bcrypt_expand0.o .zig-cache/bcrypt_port.o \
  .zig-cache/libdeflate.o \
  -O ReleaseFast -fllvm -mcpu=x86_64_v3 -fstrip --name conduit -femit-bin=bin/conduit "${CACHE[@]}"
