#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT (optional tuning in README.md).
set -euo pipefail
exec "$(dirname "$0")/target/release/conduit"
