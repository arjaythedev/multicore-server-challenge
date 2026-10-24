#!/usr/bin/env bash
# Official `loadgen search` against the app running on the simulated box (start it with app.sh first).
# Load generator pinned to LG_CPUS; users spread over NIPS loopback IPs (each gets its own ephemeral-port range,
# since this host keeps ip_local_port_range 32768-60999 and we don't change sysctls).
#   search.sh <label> [extra loadgen search flags, e.g. -start 4000 -max 120000 -warmup 0]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL="${1:?label}"; shift
LG_CPUS="${LG_CPUS:-8-19}"; PORT="${PORT:-3000}"; NIPS="${NIPS:-8}"
URLS="$(for i in $(seq 1 "$NIPS"); do printf 'http://127.0.0.%d:%s,' "$i" "$PORT"; done)"; URLS="${URLS%,}"
export CONDUIT_JWT_SECRET="${JWT_SECRET:-multicore-server-challenge}"
mkdir -p "$HERE/results" "$HERE/monitor"
cd "$HERE"
exec taskset -c "$LG_CPUS" "$HERE/bin/loadgen" search -target-ssh local -target-url "$URLS" -boxes local=1 \
  -lang "$LABEL" -no-switch -monitor "$HERE/monitor.sh" -monitor-dir "$HERE/monitor" -label "$LABEL" -outdir "$HERE/results/$LABEL" "$@"
