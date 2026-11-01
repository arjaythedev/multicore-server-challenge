#!/usr/bin/env bash
# Builds bin/conduit. Generated code (rr router, ggen codecs) is committed, so this is a plain go build.
set -euo pipefail
cd "$(dirname "$0")"
GO=/usr/local/go/bin/go
[ -x "$GO" ] || GO=go
export CGO_ENABLED=0 GOAMD64=v3
mkdir -p bin
"$GO" build -trimpath -o bin/conduit .
echo "built bin/conduit ($("$GO" version | awk '{print $3}'))"
