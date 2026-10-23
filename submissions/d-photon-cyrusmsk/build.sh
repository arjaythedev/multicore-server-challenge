#!/usr/bin/env bash
# Builds the release binary as a normal user -> bin/server. Idempotent.
set -euo pipefail
cd "$(dirname "$0")"

export PATH="/usr/local/ldc/bin:$PATH"
command -v ldc2 >/dev/null || { echo "install.sh did not put ldc2 on PATH"; exit 1; }

mkdir -p bin
# dub.selections.json pins every dependency, including the one git package
# (dpq2 pins derelict-pq by commit), so this is a reproducible build.
dub build --build=release --compiler=ldc2 --config="${CONFIG:-native}"
echo "built bin/server with $(ldc2 --version | head -1)"
