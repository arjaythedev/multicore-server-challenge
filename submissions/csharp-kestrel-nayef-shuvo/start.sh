#!/usr/bin/env bash
# Runs the server in the foreground (a native executable, no .NET runtime needed).
# Config: DATABASE_URL, JWT_SECRET, HOST, PORT, DB_POOL_SIZE (optional).
set -euo pipefail
exec "$(cd "$(dirname "$0")" && pwd)/bin/conduit"
