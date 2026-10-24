#!/usr/bin/env bash
# Builds bin/conduit with the Mojo compiler (MOJO, or mojo on PATH, or the venv install.sh creates).
set -euo pipefail
cd "$(dirname "$0")"
MOJO="${MOJO:-$(command -v mojo || echo "$HOME/mojo-env/bin/mojo")}"
mkdir -p bin
"$MOJO" build -O3 -I src src/main.mojo -o bin/conduit
echo "built bin/conduit ($("$MOJO" --version))"
