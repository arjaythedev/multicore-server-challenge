#!/usr/bin/env bash
# Compile src/main.nelua to C and that to an optimized binary, build/conduit (Nelua runs gcc).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
/opt/nelua/bin/nelua --release --no-cache --cache-dir build/cache -L src --cflags="-O2" -o build/conduit src/main.nelua
