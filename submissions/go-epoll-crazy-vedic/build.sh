#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
export PATH="/usr/local/go/bin:$PATH"
export CGO_ENABLED="${CGO_ENABLED:-1}" GOTOOLCHAIN=go1.27.2
export CGO_CXXFLAGS="${CGO_CXXFLAGS:--O3 -DNDEBUG -march=native}"
mkdir -p bin
go build -trimpath -buildvcs=false -pgo="${PGO_PROFILE:-auto}" -ldflags="-s -w" -o bin/conduit ./src
printf 'built bin/conduit (%s)\n' "$(go version)"
