#!/usr/bin/env bash
# pgss.sh <submission> <label> [users] [env]: one screen with pg_stat_statements on (local measurement only; reverted after)
S=$1; L=$2; U=${3:-12000}; E=${4:-}
P="runuser -u postgres -- psql -qX -At"
$P -c "ALTER SYSTEM SET shared_preload_libraries = pg_stat_statements" -c "ALTER SYSTEM SET pg_stat_statements.max = 2000"
systemctl restart postgresql@18-main; sleep 2
$P -d postgres -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements"
( sleep 75; $P -d postgres -c "SELECT pg_stat_statements_reset()" >/dev/null; date +%s > /root/mc/screens/pgss-reset-$L ) &
/root/mc/screen.sh $S $L $U 0.1 $E
mkdir -p /root/mc/pgss
$P -d postgres < /root/mc/pgss-dump.sql > /root/mc/pgss/$L.tsv
$P -d postgres -c "DROP EXTENSION pg_stat_statements"
$P -c "ALTER SYSTEM RESET shared_preload_libraries" -c "ALTER SYSTEM RESET pg_stat_statements.max"
systemctl restart postgresql@18-main
echo "pgss $L done: $(wc -l < /root/mc/pgss/$L.tsv) statements"
