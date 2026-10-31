#!/usr/bin/env bash
# pgsplit.sh <label> [envfile]: a screen, and Postgres CPU over 60 s of its measured window split by backend:
# read connections (the first 6 client backends to connect), write connections (the next 8), and the rest by type.
L=$1; E=${2:-/root/mc/env/on.env}
/root/mc/screen.sh fsharp-multicore-kestrel-uring-delneg $L 6000 0.1 $E &
SP=$!
sleep 100
snap() {
  sudo -u postgres psql -X -At -F' ' -d postgres -c "SELECT pid, CASE WHEN backend_type <> 'client backend' THEN replace(backend_type, ' ', '_') WHEN row_number() OVER (PARTITION BY backend_type = 'client backend' ORDER BY backend_start) <= 6 THEN 'read' ELSE 'write' END FROM pg_stat_activity WHERE backend_type <> 'client backend' OR datname LIKE 'conduit%'" |
  while read pid g; do t=$(awk '{print $14+$15}' /proc/$pid/stat 2>/dev/null) && echo "$pid $g $t"; done
}
snap > /tmp/pgs0; sleep 60; snap > /tmp/pgs1
join <(sort /tmp/pgs0) <(sort /tmp/pgs1) | awk '{d[$2]+=$5-$3} END {for (g in d) printf "pgsplit %s: %s %.3f cores\n", L, g, d[g]/100/60}' L=$L | sort
wait $SP
