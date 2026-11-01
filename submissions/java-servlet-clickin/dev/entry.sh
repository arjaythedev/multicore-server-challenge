#!/usr/bin/env bash
set -e
pg_ctlcluster 18 main start
for _ in $(seq 30); do runuser -u postgres -- pg_isready -q && break; sleep 1; done
runuser -u postgres -- psql -qX -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='conduit') THEN CREATE ROLE conduit LOGIN PASSWORD 'conduit'; END IF; END \$\$;"
runuser -u postgres -- psql -qX -c "ALTER ROLE postgres PASSWORD 'postgres'"
exec sleep infinity
