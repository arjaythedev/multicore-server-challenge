#!/usr/bin/env bash
# Install dependencies exactly as recorded in bun.lock.
set -euo pipefail

cd "$(dirname "$0")"
bun install --frozen-lockfile