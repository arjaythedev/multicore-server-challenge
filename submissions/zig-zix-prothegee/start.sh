#!/usr/bin/env bash
# Runs the server in the foreground from this directory. Required: DATABASE_URL, JWT_SECRET, HOST, PORT.
set -euo pipefail
cd "$(dirname "$0")"
exec ./zig-out/bin/conduit
