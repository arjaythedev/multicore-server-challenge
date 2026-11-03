#!/usr/bin/env bash
# CPU seconds of each Postgres process group over a window: pgsplit.sh <seconds>
# groups: application_name for client backends, backend_type for the rest (autovacuum, walwriter, ...)
snap() {
  psql -X -At -F' ' -d postgres -c "SELECT pid, coalesce(nullif(application_name, ''), backend_type) FROM pg_stat_activity" |
  while read -r pid name; do
    [ -r /proc/$pid/stat ] || continue
    t=$(awk '{print $14 + $15}' /proc/$pid/stat 2>/dev/null) || continue
    echo "$pid ${name// /_} $t"
  done
  # processes not in pg_stat_activity (checkpointer etc. are, autovacuum launcher is): all postgres pids
  for p in $(pgrep -u postgres -x postgres); do echo "$p ALL $(awk '{print $14 + $15}' /proc/$p/stat 2>/dev/null)"; done
}
snap > /tmp/pgsplit.a; sleep "$1"; snap > /tmp/pgsplit.b
hz=$(getconf CLK_TCK)
awk -v hz=$hz -v secs=$1 'NR==FNR {a[$1" "$2]=$3; next} {k=$1" "$2; if (k in a) d=$3-a[k]; else d=$3; s[$2]+=d}
  END {for (g in s) printf "%-28s %.3f cores\n", g, s[g]/hz/secs}' /tmp/pgsplit.a /tmp/pgsplit.b | sort -k2 -rn
