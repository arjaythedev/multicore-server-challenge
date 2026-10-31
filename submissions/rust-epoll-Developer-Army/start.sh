#!/usr/bin/env bash
# Launches the Conduit Apex HTTP server in the foreground.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$SCRIPT_DIR/target/release/conduit"
