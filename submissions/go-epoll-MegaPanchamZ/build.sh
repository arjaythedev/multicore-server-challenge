#!/usr/bin/env bash
# Builds the server from root package -> bin/conduit (static, -trimpath). Runs as a normal user; idempotent.
set -euo pipefail
cd "$(dirname "$0")"
GO=/usr/local/go/bin/go
[ -x "$GO" ] || GO=go
export CGO_ENABLED=0
export GOEXPERIMENT=mapsplitgroup,simd
mkdir -p bin
"$GO" build -trimpath -buildvcs=false -ldflags="-s -w" -o bin/conduit .
echo "built bin/conduit ($("$GO" version | awk '{print $3}'))"
