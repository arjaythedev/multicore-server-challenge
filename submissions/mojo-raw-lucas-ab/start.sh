#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT (SPEC.md); WORKERS optional.
set -euo pipefail
cd "$(dirname "$0")"
exec ./bin/conduit
