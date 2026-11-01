#!/usr/bin/env bash
# Builds the Swift Conduit server -> ./.build/release/Conduit.
# Idempotent. Runs as a normal user; dependencies are pinned in Package.swift + Package.resolved.
#
# Flags for every module, dependencies included (Package.swift can only set flags on its own targets):
#   -enforce-exclusivity=unchecked  no dynamic exclusivity checks in the dependencies either.
#   --static-swift-stdlib (Linux)   the Swift runtime and Foundation linked in: direct calls instead of PLT stubs.
# Not -cross-module-optimization: with it on every module, Swift 6.4 failed to link while swift-async-algorithms was
# a dependency (swiftlang/swift#91771). Release builds keep SwiftPM's default, conservative CMO.
set -euo pipefail
cd "$(dirname "$0")"
export PATH="/opt/swift/usr/bin:$PATH"
FLAGS=(-c release -Xswiftc -enforce-exclusivity=unchecked)
[ "$(uname -s)" = Linux ] && FLAGS+=(--static-swift-stdlib)
swift build "${FLAGS[@]}"
echo "built ./.build/release/Conduit ($(swift --version 2>&1 | head -1))"
