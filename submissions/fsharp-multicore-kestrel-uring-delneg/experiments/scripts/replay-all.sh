#!/usr/bin/env bash
# replay-all.sh <label> [kinds...]: dump the built submission's SQL and replay each batched kind (us PG CPU/request)
L=$1; shift
S=/opt/challenge/subs/fsharp-multicore-kestrel-uring-delneg
F=/root/mc/sql-$L.sql
cd $S && env -i PATH=/usr/bin:/bin MC_DUMP_SQL=$F DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/conduit_seed JWT_SECRET=x ${ENVS:-} bash start.sh >/dev/null 2>&1
[ -s $F ] || { echo "no dump"; exit 1; }
K="${*:-tags user article comments profile list|list shared|tag|tag shared|author|author shared|favorited|favorited shared|feed|feed shared}"
IFS="|" read -ra KS <<< "$(echo $K | sed "s/ \(user\|article\|comments\|profile\|list\)/|\1/g")"
for k in "${KS[@]}"; do printf "replay %s %-18s %s us/req\n" "$L" "$k" "$(/root/mc/replay.sh $F "$k")"; done
