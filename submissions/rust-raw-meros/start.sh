#!/usr/bin/env bash
# Runs the server in the foreground. Configuration comes only from DATABASE_URL, JWT_SECRET, HOST and PORT.
set -euo pipefail
exec "$(dirname "$0")/target/release/conduit"
