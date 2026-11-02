#!/usr/bin/env bash
# Build the Go Conduit server -> bin/conduit (static, -trimpath). Idempotent.
set -euo pipefail
cd "$(dirname "$0")"
GO=/usr/local/go/bin/go
[ -x "$GO" ] || GO=go
export CGO_ENABLED=0
mkdir -p bin
"$GO" build -trimpath -o bin/conduit ./cmd/conduit
echo "built bin/conduit ($("$GO" version | awk '{print $3}'))"
