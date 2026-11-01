#!/usr/bin/env bash
# Builds the server from source -> bin/conduit (static, -trimpath). Idempotent. Dependencies are pinned in go.sum.
# GOAMD64: v3 when a program built for v3 runs on this machine (the build host is the run host), otherwise v1.
# CONDUIT_GOAMD64=v1|v2|v3 overrides. No profile-guided optimization is used.
set -euo pipefail
cd "$(dirname "$0")"
GO=/usr/local/go/bin/go
[ -x "$GO" ] || GO=go
if [ -n "${CONDUIT_GOAMD64:-}" ]; then
  level=$CONDUIT_GOAMD64 why="CONDUIT_GOAMD64"
else
  # Let the Go runtime decide: a program built for v3 exits at startup unless the CPU (and the OS and hypervisor
  # in front of it) provides every v3 feature.
  level=v1 why="a v3 probe program did not run here"
  probe=$(mktemp -d)
  trap 'rm -rf "$probe"' EXIT
  printf 'package main\n\nfunc main() {}\n' >"$probe/main.go"
  printf 'module probe\n\ngo 1.21\n' >"$probe/go.mod"
  if (cd "$probe" && CGO_ENABLED=0 GOFLAGS= GOAMD64=v3 "$GO" build -o probe . && ./probe) >/dev/null 2>&1; then
    level=v3 why="a v3 probe program ran here"
  fi
fi
export CGO_ENABLED=0 GOFLAGS=-mod=readonly GOAMD64=$level
mkdir -p bin
"$GO" build -trimpath ${CONDUIT_BUILD_TAGS:+-tags "$CONDUIT_BUILD_TAGS"} -o bin/conduit .
echo "built bin/conduit ($("$GO" version | awk '{print $3}'), GOAMD64=$level: $why)"
