#!/usr/bin/env bash
# Builds bin/conduit from source; downloads the modules pinned in go.mod / go.sum.
set -euo pipefail
cd "$(dirname "$0")"
GO=/usr/local/go/bin/go
[ -x "$GO" ] || GO=go
CGO_ENABLED=0 GOTOOLCHAIN=local "$GO" build -trimpath -o bin/conduit .
