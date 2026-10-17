#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT.
# Optional process tuning: DB_CONNS, DB_WRITE_CONNS, APP_THREADS,
# BCRYPT_THREADS, BCRYPT_BATCH_MS, WRITE_BATCH_US. No additional configuration is required.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "${CARGO_TARGET_DIR:-$DIR/target}/release/conduit"
