#!/usr/bin/env bash
# Builds the release binary as a normal user -> build/conduit. userver 3.2 comes from install.sh.
set -euo pipefail
cd "$(dirname "$0")"
GEN=()
command -v ninja >/dev/null 2>&1 && GEN=(-G Ninja)
cmake -S . -B build "${GEN[@]}" -DCMAKE_BUILD_TYPE=Release
cmake --build build -j "$(nproc)"
