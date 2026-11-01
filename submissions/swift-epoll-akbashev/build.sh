#!/usr/bin/env bash
# Builds the server -> ./.build/release/Conduit. Runs as a normal user; no dependencies to download.
#   -enforce-exclusivity=unchecked  no dynamic exclusivity checks (the actors' state is touched by their own thread).
#   --static-swift-stdlib           the Swift runtime linked in: direct calls instead of PLT stubs.
set -euo pipefail
cd "$(dirname "$0")"
export PATH="/opt/swift/usr/bin:$PATH"
FLAGS=(-c release -Xswiftc -enforce-exclusivity=unchecked)
[ "$(uname -s)" = Linux ] && FLAGS+=(--static-swift-stdlib)
swift build "${FLAGS[@]}"
echo "built ./.build/release/Conduit ($(swift --version 2>&1 | head -1))"
