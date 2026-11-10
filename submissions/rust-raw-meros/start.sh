#!/usr/bin/env bash
# Runs the server in the foreground. Required: DATABASE_URL, JWT_SECRET; optional: HOST, PORT and the tuning variables listed in README.md.
set -euo pipefail
exec "$(dirname "$0")/target/release/conduit"
