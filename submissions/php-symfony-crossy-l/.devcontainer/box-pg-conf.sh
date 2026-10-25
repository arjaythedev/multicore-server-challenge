#!/usr/bin/env bash
# Runs the benchmark box's own Postgres tuning script (box/pg-conf.sh) for the box's size, whatever
# machine this image is built on. That script reads the core count from nproc and the memory from
# /proc/meminfo; here both answers are fixed to 8 vCPU and 15990 MiB (the box's 16 GB).
#
# Usage: box-pg-conf.sh <path to box/pg-conf.sh> [--print]
set -euo pipefail

nproc() { echo 8; }
awk() {
  if [[ "$*" == *MemTotal* ]]; then echo 16373760; else command awk "$@"; fi
}
export -f nproc awk

script="${1:?usage: box-pg-conf.sh <path to box/pg-conf.sh> [--print]}"
shift
exec bash "$script" "$@"
