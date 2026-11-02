#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT.
# Optional knobs (defaults suit the 8 vCPU box): DOMAINS, PLANNER_WAIT_US, PLANNER_LOOPS, PLANNER_CONNS,
# PG_CONNS_PER_DOMAIN, BCRYPT_THREADS, BCRYPT_WAIT_MS; diagnostics GC_STATS=1, MEMPROF=<rate>.
set -euo pipefail
# 4M-word (32 MB) minor heap per domain, and a lazier major GC (space_overhead 400): at saturation a third of
# what is allocated outlives a minor GC, and fewer major cycles cost less CPU for ~0.3 GB more memory
export OCAMLRUNPARAM="${OCAMLRUNPARAM:-s=4M,o=400}"
exec "$(cd "$(dirname "$0")" && pwd)/bin/conduit"
