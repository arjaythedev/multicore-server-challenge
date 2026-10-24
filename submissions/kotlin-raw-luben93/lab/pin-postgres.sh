#!/usr/bin/env bash
# Pins every running Postgres process (and so every future backend, forked from the postmaster) to CPUS,
# so the server + Postgres share the same cores as on the box.   lab/pin-postgres.sh 0-7
set -euo pipefail
CPUS=${1:-0-7}
for p in $(pgrep -u postgres); do taskset -pc "$CPUS" "$p" >/dev/null; done
echo "postgres pinned to $CPUS ($(pgrep -u postgres | wc -l) processes)"
