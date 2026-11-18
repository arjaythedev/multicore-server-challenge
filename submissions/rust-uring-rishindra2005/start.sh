#!/usr/bin/env bash
# Runs the server in the foreground.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

exec ./target/release/rust-uring-rishindra2005
