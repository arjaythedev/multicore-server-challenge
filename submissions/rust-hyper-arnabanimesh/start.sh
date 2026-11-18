#!/usr/bin/env bash
# Runs the server in the foreground. Configuration comes from the environment described in SPEC.md
# (DATABASE_URL, JWT_SECRET, HOST, PORT). Optional tuning knobs: APP_THREADS, DB_CONNS_PER_THREAD,
# BCRYPT_THREADS, BCRYPT_NICE (see README.md).
set -euo pipefail
cd "$(dirname "$0")"
exec ./target/release/conduit