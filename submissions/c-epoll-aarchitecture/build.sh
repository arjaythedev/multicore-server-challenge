#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
make
test -x bin/conduit
echo "built bin/conduit"
