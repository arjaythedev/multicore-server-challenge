#!/usr/bin/env bash
# Runs the server in the foreground. Configuration: DATABASE_URL, JWT_SECRET, HOST, PORT (environment only).
set -euo pipefail
exec "$(cd "$(dirname "$0")" && pwd)/bin/conduit"
