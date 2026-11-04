#!/usr/bin/env bash
# Runs the server in the foreground. Configured strictly by SPEC environment variables.
set -euo pipefail
exec "$(dirname "$0")/bin/server"
