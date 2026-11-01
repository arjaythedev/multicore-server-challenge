#!/usr/bin/env bash
# holdprobe.sh <label> <users>: hold.sh plus an independent probe every 2 s (curl GET /api/tags and GET /api/articles
# latency, established :80 sockets, loadgen state), to tell a stalled server from a stalled load generator.
L=$1; U=$2; P=/root/mc/holds/$L.probe; : > $P
/root/mc/hold.sh fsharp-multicore-kestrel-uring-delneg $L $U /root/mc/env/on.env &
H=$!
sleep 15
while kill -0 $H 2>/dev/null; do
  t1=$(curl -s -o /dev/null -m 10 -w "%{http_code}/%{time_total}" http://127.0.0.1/api/tags)
  t2=$(curl -s -o /dev/null -m 10 -w "%{http_code}/%{time_total}" "http://127.0.0.1/api/articles?limit=10")
  est=$(ss -Htn state established "( sport = :80 )" | wc -l)
  lg=$(ps -o stat=,pcpu=,rss= -C conduit-loadgen | head -1)
  echo "$(date +%T) tags $t1 list $t2 est80 $est lg [$lg]" >> $P
  sleep 2
done
wait $H
echo "holdprobe $L: $(awk "{print \$3}" $P | sort | uniq -c | sort -rn | head -3 | tr "\n" " ") max_tags_s $(awk "{split(\$3,a,\"/\"); if (a[2]>m) m=a[2]} END {print m}" $P)"
