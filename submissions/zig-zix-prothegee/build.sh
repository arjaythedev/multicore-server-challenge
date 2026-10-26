#!/usr/bin/env bash
# Builds the release server -> zig-out/bin/conduit. The pinned zix dependency is fetched on the first build.
set -euo pipefail
cd "$(dirname "$0")"

# Keep the build cache with the submission so the build does not depend on HOME.
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$PWD/.zig-global}"

zig build -Doptimize=ReleaseFast

echo "built zig-out/bin/conduit (zig $(zig version))"
