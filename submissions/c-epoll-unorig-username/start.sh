#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT.
set -euo pipefail
exec "$(cd "$(dirname "$0")" && pwd)/bin/conduit"
