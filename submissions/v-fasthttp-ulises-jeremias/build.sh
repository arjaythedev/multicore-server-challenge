#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
mkdir -p bin
VJOBS="${VJOBS:-1}" v -prod -prealloc -d new_veb -o bin/conduit .
