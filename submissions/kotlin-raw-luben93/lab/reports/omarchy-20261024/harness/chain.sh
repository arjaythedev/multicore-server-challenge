#!/usr/bin/env bash
# Calibration + kraw-jvm capacity + sweep, sequential. Run from the repo root.
set -uo pipefail
source /home/luben/code/UC/.tmp/mcsc-help/lab-env.sh
export PER_TARGET=25000
L=submissions/kotlin-raw-luben93/lab
echo "### vertx $(date +%T)"; $L/capacity.sh submissions/kotlin-vertx-canleon vertx 1.0 16000 32000 46000 64000
echo "### kraw-jvm $(date +%T)"; out=$($L/capacity.sh submissions/kotlin-raw-luben93 kraw-jvm 1.0 32000 64000 90000 120000 | tee /dev/stderr)
echo "$out"
echo "### rust $(date +%T)"; $L/capacity.sh submissions/rust-tokio-Scooter1337 rust 1.0 32000 64000 90000 120000
LVL=$(echo "$out" | sed -n 's/^LAST PASS: kraw-jvm users=\([0-9]*\).*/\1/p'); LVL=${LVL:-32000}
echo "### sweep at $LVL $(date +%T)"
for h in 1 2 3; do echo "HTTP_THREADS=$h DB_READ_CONNS=6"; HTTP_THREADS=$h DB_READ_CONNS=6 TAG=kraw-h$h-r6 $L/bench.sh submissions/kotlin-raw-luben93 $LVL 1.0 | tail -1; done
for r in 4 8; do echo "HTTP_THREADS=2 DB_READ_CONNS=$r"; HTTP_THREADS=2 DB_READ_CONNS=$r TAG=kraw-h2-r$r $L/bench.sh submissions/kotlin-raw-luben93 $LVL 1.0 | tail -1; done
echo "### done $(date +%T)"
