#!/usr/bin/env bash
# Builds bin/conduit with the Mojo compiler: $MOJO, else the one install.sh puts in /opt/mojo, else mojo on PATH,
# else a local development venv in ~/mojo-env.
set -euo pipefail
cd "$(dirname "$0")"
if [ -z "${MOJO:-}" ]; then
  if [ -x /opt/mojo/bin/mojo ]; then MOJO=/opt/mojo/bin/mojo
  else MOJO="$(command -v mojo || echo "$HOME/mojo-env/bin/mojo")"; fi
fi
mkdir -p bin
"$MOJO" build -O3 -I src src/main.mojo -o bin/conduit
echo "built bin/conduit ($("$MOJO" --version))"
