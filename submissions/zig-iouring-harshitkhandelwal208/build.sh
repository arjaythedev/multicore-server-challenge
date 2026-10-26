#!/usr/bin/env bash
# Builds bin/conduit from source with the pinned Zig toolchain. No dependencies beyond the Zig standard library.
set -euo pipefail
cd "$(dirname "$0")"
ZIG="$(command -v zig || echo /opt/zig/zig)"
mkdir -p bin
# -Dcpu=native: this is built on the machine that runs it (SHA-NI / AVX2 paths are picked by the compiler).
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$PWD/.zig-cache/global}"
"$ZIG" build -Doptimize=ReleaseFast -Dcpu=native --prefix . --prefix-exe-dir bin --cache-dir .zig-cache
ls -l bin/conduit
