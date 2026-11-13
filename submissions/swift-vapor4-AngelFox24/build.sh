#!/usr/bin/env bash
# Builds the release binary as a normal user -> .build/release/SwiftVaporAngelfox.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release --product SwiftVaporAngelfox
