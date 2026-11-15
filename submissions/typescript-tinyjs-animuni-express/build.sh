#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
bun install --frozen-lockfile
bun test src
bun node_modules/tinyjs-fullstack/bin/tinyjs.js build
if [ "${GITHUB_ACTIONS:-}" = true ]; then
  bun test integration.test.ts
fi
