#!/usr/bin/env bash
# Runs the release in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT, and optionally DB_POOL_SIZE.
# The VM flags are the release's own: rel/vm.args.eex and rel/env.sh.eex.
set -euo pipefail
cd "$(dirname "$0")"
exec _build/prod/rel/conduit/bin/conduit start
