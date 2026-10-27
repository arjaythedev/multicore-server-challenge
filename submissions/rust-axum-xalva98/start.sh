#!/usr/bin/env bash
# Runs the release binary in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT (and the optional
# knobs in README.md).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "${CARGO_TARGET_DIR:-$DIR/target}/release/conduit"
