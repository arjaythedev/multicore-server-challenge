#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
compiler="$(command -v zig || true)"
if [ "$(uname -s)" = Linux ]; then
    if [ -x /opt/conduit-zig-tools/zig-0.17.0/zig ]; then compiler=/opt/conduit-zig-tools/zig-0.17.0/zig; fi
    export PGROOT="${PGROOT:-/opt/conduit-zig-tools/postgresql-18.6}"
elif [ -z "${PGROOT:-}" ]; then
    source dev/env.sh
    compiler="$(command -v zig || true)"
fi
if [ -z "$compiler" ] || [ "$("$compiler" version)" != 0.17.0 ]; then
    echo 'Zig 0.17.0 is required; run the platform setup first.' >&2
    exit 1
fi
args=()
if [ -n "${PGROOT:-}" ]; then args+=("-Dpg-root=$PGROOT"); fi
"$compiler" build -Doptimize=ReleaseFast "${args[@]}"
