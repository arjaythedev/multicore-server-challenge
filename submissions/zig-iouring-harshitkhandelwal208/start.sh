#!/usr/bin/env bash
# Runs the server in the foreground. Configuration: DATABASE_URL, JWT_SECRET, HOST, PORT (see SPEC.md).
set -euo pipefail
cd "$(dirname "$0")"
exec bin/conduit
