#!/usr/bin/env bash
# After chain.sh: update kraw-jvm, native capacity, then official searches for both Kotlin builds.
set -uo pipefail
H=/home/luben/code/UC/.tmp/mcsc-help; J=/home/luben/code/UC/.tmp/multicore-server-challenge; N=/home/luben/code/UC/.tmp/mcs-native
while pgrep -f "$H/chain.sh" >/dev/null; do sleep 15; done
source $H/lab-env.sh; export PER_TARGET=25000
cd $J && git diff -- submissions/kotlin-raw-luben93/lab/bench.sh > $H/bench-nt.patch && git checkout -q -- submissions/kotlin-raw-luben93/lab/bench.sh \
  && git pull -q --ff-only origin kotlin-raw-luben93 && git apply $H/bench-nt.patch && echo "### jvm now $(git log --oneline -1)"
(cd $J/submissions/kotlin-raw-luben93 && bash build.sh) | tail -1
L=$J/submissions/kotlin-raw-luben93/lab
echo "### kraw-native capacity $(date +%T)"; $L/capacity.sh $N/submissions/kotlin-native-luben93 kraw-native 1.0 32000 64000 90000 120000 140000
echo "### search kraw-jvm $(date +%T)"
$H/app.sh start $J/submissions/kotlin-raw-luben93 && $H/search.sh search-kraw-jvm -start 8000 -max 160000 | tail -25
echo "### search kraw-native $(date +%T)"
$H/app.sh start $N/submissions/kotlin-native-luben93 && $H/search.sh search-kraw-native -start 8000 -max 160000 | tail -25
$H/app.sh stop
echo "### done $(date +%T)"
