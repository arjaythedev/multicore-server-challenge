#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT.
# Optional process tuning: DB_CONNS, DB_WRITE_CONNS, APP_THREADS,
# BCRYPT_THREADS, BCRYPT_BATCH_MS, WRITE_BATCH_US, READ_BATCH_SIZE, READ_BATCH_US, READ_SQL_BATCH, DB_THREADS, HTTP_GZIP,
# HTTP_GZIP_ABOVE_MBS.
# No additional configuration is required.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
export READ_TAG_ROUTE="${READ_TAG_ROUTE:-1}"
export READ_COMMENT_SET="${READ_COMMENT_SET:-1}"
export READ_TAG_BATCH="${READ_TAG_BATCH:-1}"
exec "${CARGO_TARGET_DIR:-$DIR/target}/release/conduit"
