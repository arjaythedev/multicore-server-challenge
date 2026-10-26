#!/usr/bin/env bash
# Alternating fixed-load comparison. For each round, every contender is measured once, in the same order, so slow drift of
# the machine (thermals, background daemons) hits all of them alike.
#
#   usage: run.sh ROUNDS label=SERVER_DIR[|K=V,K=V] [label=SERVER_DIR ...]
#
# `label` names the line in the output; `SERVER_DIR` holds the contender's start.sh; `K=V,...` are environment variables for
# that contender only (e.g. READ_WINDOW_US=20000). Output: one line per run, printed and in $RESULTS/<tag>.* files.
#
#   env: USERS (default 22000), SCALE (0.5), MEASURE (40), RAMP (10), TAGPREFIX (run), RESULTS (./results),
#        PG_RESTART (a command run before every measurement, e.g. "bash ../pgrestart.sh"; empty = no restart),
#        SRV_CPUS (default 0,6), LG_CPUS (default 4,5,10,11), plus what bench.py reads
set -u
cd "$(dirname "$0")"
export RESULTS="${RESULTS:-$PWD/results}"
mkdir -p "$RESULTS"
rounds=$1; shift
for i in $(seq "$rounds"); do
  for kv in "$@"; do
    label=${kv%%=*}; rest=${kv#*=}; dir=${rest%%|*}; extra=()
    if [ "$rest" != "$dir" ]; then
      IFS=, read -ra kvs <<< "${rest#*|}"
      for x in "${kvs[@]}"; do extra+=(--env "$x"); done
    fi
    [ -n "${PG_RESTART:-}" ] && $PG_RESTART >/dev/null 2>&1
    out=$(python3 bench.py --server "$dir" --users "${USERS:-22000}" --scale "${SCALE:-0.5}" --ramp "${RAMP:-10}" --measure "${MEASURE:-40}" \
          --tag "${TAGPREFIX:-run}-$label-$i" "${extra[@]}" 2>&1 | tail -3)
    printf '%s r%s: ' "$label" "$i"
    printf '%s\n' "$out" | python3 "$(dirname "$0")/parse_run.py"
  done
done
