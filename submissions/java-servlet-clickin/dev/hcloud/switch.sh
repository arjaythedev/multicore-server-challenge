#!/usr/bin/env bash
# /opt/conduit-tools/switch.sh <lang>: fresh DB copy from the seed, caches dropped, app restarted and healthy.
set -euo pipefail
systemctl stop challenge || true
runuser -u postgres -- psql -qX -c "DROP DATABASE IF EXISTS conduit WITH (FORCE)" -c "CREATE DATABASE conduit TEMPLATE conduit_seed STRATEGY FILE_COPY"
systemctl restart postgresql@18-main; sync; echo 3 > /proc/sys/vm/drop_caches
for _ in $(seq 30); do runuser -u postgres -- pg_isready -q && break; sleep 1; done
systemctl start challenge
for _ in $(seq 60); do curl -sf -o /dev/null http://127.0.0.1/api/tags && { echo healthy; exit 0; }; sleep 1; done
echo "not healthy"; journalctl -u challenge -n 30 --no-pager; exit 1
