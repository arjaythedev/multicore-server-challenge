#!/usr/bin/env bash
# Builds bin/bcbench, the bcrypt kernel timer (src/bcrypt/bench.zig), from the kernel objects build.sh leaves in
# .zig-cache. Run build.sh first. Example: bin/bcbench 9; perf stat -e instructions bin/bcbench --batches 20 asm_shrx:5
set -euo pipefail
cd "$(dirname "$0")/.."
ZIG=/opt/zig-0.17.0/zig
[ -x "$ZIG" ] || ZIG=zig
"$ZIG" build-exe src/bcrypt/bench.zig .zig-cache/bcrypt_kernels.o .zig-cache/bcrypt_expand0.o .zig-cache/bcrypt_port.o \
  -O ReleaseFast -fllvm -mcpu=x86_64_v3 -fstrip --name bcbench -femit-bin=bin/bcbench \
  --cache-dir .zig-cache --global-cache-dir .zig-cache/global
