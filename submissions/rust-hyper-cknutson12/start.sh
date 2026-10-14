#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT.
# Optional tuning (defaults are what the benchmark runs): DB_CONNS (2 x cores), APP_THREADS (cores),
# BCRYPT_THREADS (cores - 1).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "${CARGO_TARGET_DIR:-$DIR/target}/release/conduit"
