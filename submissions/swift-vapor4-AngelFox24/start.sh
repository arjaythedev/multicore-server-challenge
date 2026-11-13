#!/usr/bin/env bash
# Runs the server in the foreground. Configured only by DATABASE_URL, JWT_SECRET, HOST and PORT.
set -euo pipefail
cd "$(dirname "$0")"
exec ./.build/release/SwiftVaporAngelfox
