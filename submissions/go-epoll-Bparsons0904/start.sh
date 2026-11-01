#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT.
# CONDUIT_BATCH_SHARING=0 turns off in-batch sharing of identical queries (see README).
set -euo pipefail
exec "$(cd "$(dirname "$0")" && pwd)/bin/conduit"
