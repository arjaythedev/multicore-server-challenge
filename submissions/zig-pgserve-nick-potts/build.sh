#!/usr/bin/env bash
# Runs as `challenge` (score/prepare.sh, clean PATH). Builds the launcher; the engine was built by install.sh.
set -euo pipefail
cd "$(dirname "$0")"
/usr/local/bin/zig cc -O2 -Wall -o launcher launcher.c
