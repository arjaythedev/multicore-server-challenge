#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

DEX_VERSION="${DEX_VERSION:-v0.9.28}"

if [ -n "${DEX_BIN:-}" ]; then
  DEX="$DEX_BIN"
else
  export PATH="/usr/local/go/bin:$PATH"
  export GOBIN="$PWD/.bin"
  go install "github.com/ensamuel7/dex@${DEX_VERSION}"
  DEX="$GOBIN/dex"
fi

"$DEX" version
"$DEX" mod download
"$DEX" build server.dx

test -x build/server
echo "built build/server"
