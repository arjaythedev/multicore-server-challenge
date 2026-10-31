
#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

export NODE_ENV="${NODE_ENV:-production}"
export HOST="${HOST:-0.0.0.0}"
export PORT="${PORT:-3110}"

exec node dist/cluster.js
