#!/usr/bin/env bash
# Builds the load generator with live.go added, leaving bench/ untouched. Usage: build.sh <out-binary>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/../../../../.." && pwd)"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cp -r "$ROOT/bench/." "$W/"
cp "$HERE/live.go" "$W/cmd/loadgen/live.go"
sed -i 's|^\t\ttl = append(tl, s)$|\t\tliveEmit(\&s)\n\t\ttl = append(tl, s)|' "$W/cmd/loadgen/run.go"
sed -i 's|^\tcase "run":$|\tcase "live-read":\n\t\tos.Exit(cmdLiveRead(args))\n\tcase "run":|' "$W/cmd/loadgen/main.go"
grep -q liveEmit "$W/cmd/loadgen/run.go"; grep -q cmdLiveRead "$W/cmd/loadgen/main.go"
cd "$W"; CGO_ENABLED=0 go build -o "$1" ./cmd/loadgen
