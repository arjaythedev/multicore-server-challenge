#!/usr/bin/env bash
# Builds the Swift Conduit server -> ./.build/release/Conduit.
# Idempotent. Runs as a normal user; dependencies are pinned in Package.swift + Package.resolved.
#
# Flags for every module, dependencies included (Package.swift can only set flags on its own targets):
#   -enforce-exclusivity=unchecked  no dynamic exclusivity checks in the dependencies either.
#   --static-swift-stdlib (Linux)   the Swift runtime and Foundation linked in: direct calls instead of PLT stubs.
#   -target-cpu <this CPU>          code for the CPU it is built on, which is the box's (rule 11: built on the box), as
#                                   rust-epoll-theCatWisel's target-cpu=native: the CPU's own instructions and cost
#                                   model (on AMD, bextr for bcrypt's byte extraction). Swift has no "native", so the
#                                   toolchain's clang says which CPU it detects; nothing is added if it can't tell.
# Not -cross-module-optimization: with it on every module, Swift 6.4 failed to link while swift-async-algorithms was
# a dependency (swiftlang/swift#91771). Release builds keep SwiftPM's default, conservative CMO.
set -euo pipefail
cd "$(dirname "$0")"
export PATH="/opt/swift/usr/bin:$PATH"
FLAGS=(-c release -Xswiftc -enforce-exclusivity=unchecked)
[ "$(uname -s)" = Linux ] && FLAGS+=(--static-swift-stdlib)
CPU=$(clang -march=native -### -c -x c /dev/null 2>&1 | grep -o '"-target-cpu" "[^"]*"' | cut -d'"' -f4 || true)
if [ -n "$CPU" ] && [ "$CPU" != generic ]; then
  FLAGS+=(-Xswiftc -target-cpu -Xswiftc "$CPU")
fi
swift build "${FLAGS[@]}"
echo "built ./.build/release/Conduit for ${CPU:-a generic CPU} ($(swift --version 2>&1 | head -1))"
