#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
JWT_SECRET=multicore-server-challenge
source "$HERE/scripts/local-server.sh"

local_preflight
local_workspace conformance
local_build_tools conformance
local_database
local_start_server

echo "== full upstream conformance suite"
rc=0
benchmark_compose run --rm --no-deps --entrypoint "$WORK/conformance" loadgen \
    -base "$BASE" -secret "$JWT_SECRET" \
    -transcript "$WORK/transcript.jsonl" | tee "$WORK/conformance.log" || rc=$?
steps="$(wc -l < "$WORK/transcript.jsonl" | tr -d '[:space:]')"
if [[ "$steps" != 197 ]]; then
    echo "Expected exactly 197 upstream steps, got $steps"
    rc=1
fi
if [[ "$rc" != 0 ]]; then
    echo "== server log (last 30 lines)"
    tail -30 "$WORK/server.log"
fi
exit "$rc"
