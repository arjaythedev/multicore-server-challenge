#!/usr/bin/env bash
# After chain2: bcrypt lanes and DB_READ_CONNS=4 at higher load, kraw-jvm.
set -uo pipefail
H=/home/luben/code/UC/.tmp/mcsc-help; J=/home/luben/code/UC/.tmp/multicore-server-challenge
while pgrep -f "$H/chain2.sh" >/dev/null; do sleep 15; done
source $H/lab-env.sh; export PER_TARGET=25000
L=$J/submissions/kotlin-raw-luben93/lab; S=$J/submissions/kotlin-raw-luben93
for b in 2 3; do echo "BCRYPT_THREADS=$b"; BCRYPT_THREADS=$b TAG=kraw-b$b $L/bench.sh $S 120000 1.0 | tail -1; done
for u in 130000 140000; do echo "DB_READ_CONNS=4 BCRYPT_THREADS=2 u=$u"; DB_READ_CONNS=4 BCRYPT_THREADS=2 TAG=kraw-r4-b2 $L/bench.sh $S $u 1.0 | tail -1; done
echo "### done $(date +%T)"
