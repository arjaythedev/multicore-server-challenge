#!/usr/bin/env bash
# Builds the Swift Conduit server -> ./.build/release/Conduit (release, static stdlib not required).
# Idempotent. Runs as a normal user; dependencies are pinned in Package.swift + Package.resolved.
set -euo pipefail
cd "$(dirname "$0")"
export PATH="/opt/swift/usr/bin:$PATH"
swift build -c release
echo "built ./.build/release/Conduit ($(swift --version | head -1))"
