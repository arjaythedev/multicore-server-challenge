#!/usr/bin/env bash
# After chain4: eventfd-drain fix A/B at 120k, plus server idle CPU right after the load ends.
set -uo pipefail
H=/home/luben/code/UC/.tmp/mcsc-help; J=/home/luben/code/UC/.tmp/multicore-server-challenge
while pgrep -f "$H/chain[234].sh" >/dev/null; do sleep 15; done
source $H/lab-env.sh; export PER_TARGET=25000
L=$J/submissions/kotlin-raw-luben93/lab
for v in orig:/home/luben/code/UC/.tmp/mcs-native fix:/home/luben/code/UC/.tmp/mcs-native-fix; do
  IFS=: read name dir <<<"$v"
  echo "native-$name 120k"; KEEP=1 TAG=knat-$name $L/bench.sh $dir/submissions/kotlin-native-luben93 120000 1.0 | tail -1
  sleep 20; P=$(fuser 3000/tcp 2>/dev/null | awk '{print $1}')
  a=$(awk '{print $14+$15}' /proc/$P/stat); sleep 10; b=$(awk '{print $14+$15}' /proc/$P/stat)
  echo "native-$name idle CPU 20-30 s after load: $(( (b-a)*100/1000 ))% of one core"; kill $P; sleep 2
done
echo "### done $(date +%T)"
