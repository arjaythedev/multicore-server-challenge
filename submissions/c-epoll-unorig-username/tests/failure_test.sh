#!/bin/bash
# Failure tests on a dev-seed copy: bad requests in a group, backends killed, Postgres crashed and down, descriptor exhaustion. Run as root with Postgres on the same machine, from the repo root copied to /r.
cd "$(dirname "$0")/.." && bash build.sh >/dev/null 2>&1
export PGUSER=postgres PGHOST=/var/run/postgresql
psql -d postgres -qXc "DROP DATABASE IF EXISTS asan WITH (FORCE)" -c "CREATE DATABASE asan TEMPLATE conduit_dev STRATEGY FILE_COPY" 2>/dev/null
export DATABASE_URL=postgres://conduit:conduit@127.0.0.1:5432/asan JWT_SECRET=dev-secret HOST=127.0.0.1 PORT=3110
ulimit -n 100000; bin/conduit > /tmp/f.log 2>&1 &
PID=$!; sleep 2
python3 tests/failure_test.py; RC=$?
kill -0 $PID && echo "SERVER ALIVE" || echo "SERVER DIED"; kill $PID 2>/dev/null; wait $PID 2>/dev/null
sort /tmp/f.log | uniq -c | sort -rn | head -6 | cut -c1-110
# descriptor exhaustion: a low limit and more clients than descriptors, then recovery
(ulimit -n 300; exec bin/conduit > /tmp/f2.log 2>&1) &
PID=$!; sleep 2
python3 - <<'PY'
import socket,time,urllib.request
ss=[]
for i in range(1500):
    s=socket.socket(); s.settimeout(2)
    try: s.connect(('127.0.0.1',3110)); ss.append(s)
    except Exception as e: pass
print('opened',len(ss)); time.sleep(3)
for s in ss[:1300]: s.close()
time.sleep(2)
print('after EMFILE: tags status', urllib.request.urlopen('http://127.0.0.1:3110/api/tags',timeout=8).status)
PY
kill -0 $PID && echo "SERVER ALIVE AFTER EMFILE" || echo "SERVER DIED AT EMFILE"; kill $PID 2>/dev/null
