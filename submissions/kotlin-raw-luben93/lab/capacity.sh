#!/usr/bin/env bash
# Steps users up until a run fails (like the scorer's probes); prints the last pass.
#   lab/capacity.sh <submission-dir> <tag> <think-scale> <users...>
# e.g. lab/capacity.sh submissions/rust-tokio-Scooter1337 rust 1.0 16000 32000 64000 90000 120000
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DIR=$1; TAG=$2; SCALE=$3; shift 3
last=""
for u in "$@"; do
  line=$(TAG=$TAG "$HERE/bench.sh" "$DIR" "$u" "$SCALE" ${MEAS:-60} ${RAMP:-60} 2>&1 | tail -1)
  echo "$line"
  case "$line" in *pass=True*) last="$line" ;; *) break ;; esac
done
echo "LAST PASS: ${last:-none}"
