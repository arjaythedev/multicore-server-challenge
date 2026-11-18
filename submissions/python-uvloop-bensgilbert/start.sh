#!/usr/bin/env bash
# Runs the server in the foreground. Config is DATABASE_URL, JWT_SECRET, HOST and PORT (SPEC.md). Workers and Postgres
# connections are sized from the CPU count (see README.md); WORKERS, DB_CONNECTIONS and HASH_THREADS override that
# for local experiments.
set -euo pipefail
cd "$(dirname "$0")"
exec .venv/bin/python -m conduit
