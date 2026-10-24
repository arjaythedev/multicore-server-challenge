#!/usr/bin/env bash
# After chain3: is kraw-native limited by its 2 HTTP loop threads?
set -uo pipefail
H=/home/luben/code/UC/.tmp/mcsc-help; J=/home/luben/code/UC/.tmp/multicore-server-challenge; N=/home/luben/code/UC/.tmp/mcs-native
while pgrep -f "$H/chain[23].sh" >/dev/null; do sleep 15; done
source $H/lab-env.sh; export PER_TARGET=25000
L=$J/submissions/kotlin-raw-luben93/lab
for h in 3 4; do echo "native HTTP_THREADS=$h"; HTTP_THREADS=$h TAG=knat-h$h $L/bench.sh $N/submissions/kotlin-native-luben93 120000 1.0 | tail -1; done
echo "### done $(date +%T)"
