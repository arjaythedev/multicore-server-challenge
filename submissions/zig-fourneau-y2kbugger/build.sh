#!/usr/bin/env bash
# Builds bin/conduit as a normal user. Zig fetches fourneau at the commit
# build.zig.zon pins and checks it against its hash.
set -euo pipefail
cd "$(dirname "$0")"
ZIG="${ZIG:-/usr/local/zig-0.17.0/zig}"
"$ZIG" build -Doptimize=fast --prefix . --summary none
