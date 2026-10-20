#!/usr/bin/env bash
# Runs the release binary in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT.
set -euo pipefail
exec "$(cd "$(dirname "$0")" && pwd)/target/release/conduit-urus"
