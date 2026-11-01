#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT.
# Optional knobs (defaults suit the 8 vCPU box): DOMAINS, PLANNER_WAIT_US, PLANNER_LOOPS, PLANNER_CONNS,
# PG_CONNS_PER_DOMAIN, BCRYPT_THREADS, BCRYPT_WAIT_MS.
set -euo pipefail
# 4M-word (32 MB) minor heap per domain: a batch's rows rarely live long enough to be promoted
export OCAMLRUNPARAM="${OCAMLRUNPARAM:-s=4M}"
exec "$(cd "$(dirname "$0")" && pwd)/bin/conduit"
