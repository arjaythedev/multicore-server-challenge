#!/usr/bin/env bash
set -euo pipefail

# SPEC.md defines runtime contract env vars like $PORT and $DATABASE_URL
cd "$(dirname "$0")"
exec .venv/bin/python -m conduit_server.main
