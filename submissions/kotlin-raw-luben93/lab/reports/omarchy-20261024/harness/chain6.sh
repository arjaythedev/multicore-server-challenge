#!/usr/bin/env bash
# After chain2: reproduce the kraw-jvm overload wedge (160k), thread dumps during it, then check recovery.
set -uo pipefail
H=/home/luben/code/UC/.tmp/mcsc-help; J=/home/luben/code/UC/.tmp/multicore-server-challenge
while pgrep -f "$H/chain2.sh" >/dev/null; do sleep 15; done
source $H/lab-env.sh; O=$H/wedge; mkdir -p $O
URLS=$(for i in $(seq 1 8); do printf 'http://127.0.0.%d:3000,' $i; done); URLS=${URLS%,}
cpu() { awk '{print $14+$15}' /proc/$1/stat; }
$H/app.sh start $J/submissions/kotlin-raw-luben93 || exit 1
JP=$(pgrep -f 'conduit.MainKt' | head -1); echo "jvm pid $JP"
taskset -c 8-19 $H/bin/loadgen run -target "$URLS" -users 160000 -ramp 60s -measure 40s -tail 5s -secret multicore-server-challenge \
  -run-id wedge$(date +%s) -q -out $O/lg160.json > $O/lg160.log 2>&1 &
LG=$!
for t in 50 60 70 80 90; do sleep 10; a=$(cpu $JP); sleep 1; b=$(cpu $JP)
  echo "t~${t}s jvm cpu $(( b - a ))% of one core, curl: $(curl -s -m 3 -o /dev/null -w '%{http_code} %{time_total}s' http://127.0.0.1:3000/api/tags)"; done
$H/jdk27/bin/jstack -l $JP > $O/jstack-1.txt 2>&1; sleep 5; $H/jdk27/bin/jstack -l $JP > $O/jstack-2.txt 2>&1
wait $LG; echo "lg160 done: $(grep -o '"error_rate":[0-9.e-]*' $O/lg160.json | head -1)"
sleep 30; a=$(cpu $JP); sleep 5; b=$(cpu $JP)
echo "30 s after load: jvm cpu $(( (b-a)*100/500 ))%, curl: $(curl -s -m 5 -o /dev/null -w '%{http_code} %{time_total}s' http://127.0.0.1:3000/api/tags)"
taskset -c 8-19 $H/bin/loadgen run -target "$URLS" -users 2000 -ramp 5s -measure 20s -tail 3s -secret multicore-server-challenge \
  -run-id wedgepost$(date +%s) -out $O/lg-post.json 2>&1 | grep -E '^ALL|verdict'
$H/jdk27/bin/jstack -l $JP > $O/jstack-3-after.txt 2>&1
cp $H/app.log $O/server.log; $H/app.sh stop
echo "### done $(date +%T)"
