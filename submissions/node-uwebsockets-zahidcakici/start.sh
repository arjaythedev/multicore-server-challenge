#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT (optional tuning: README.md).
set -euo pipefail
cd "$(dirname "$0")"
exec /opt/node-v24.21.0/bin/node --max-semi-space-size=32 server.js
