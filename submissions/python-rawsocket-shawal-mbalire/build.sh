#!/usr/bin/env bash
set -euo pipefail

# Build: create project-local virtualenv and install exactly-pinned deps
# constraints.txt locks every package (transitives included); start.sh runs that venv.
cd "$(dirname "$0")"
python3 -m venv .venv
.venv/bin/pip install --no-cache-dir --upgrade 'pip==26.2.2'
.venv/bin/pip install --no-cache-dir -c constraints.txt psycopg psycopg_pool bcrypt pyjwt
