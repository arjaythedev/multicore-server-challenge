#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT.
# Apply the selected submission settings before Go initializes package state.
set -euo pipefail
submission_dir="$(cd "$(dirname "$0")" && pwd)"
set -a
. "$submission_dir/config/tuned.env"
set +a
exec "$submission_dir/bin/conduit"
