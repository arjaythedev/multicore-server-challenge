#!/usr/bin/env bash
# Allocation profile: a local load run with JFR, then the top allocating classes and sites. Usage: bash dev/alloc.sh [users]
set -euo pipefail
cd "$(dirname "$0")/.."
docker exec cbox bash -c 'cd /repo/submissions/java-servlet-clickin && PATH=/opt/jdk/bin:$PATH bash build.sh >/dev/null'
JOPTS="-XX:StartFlightRecording=filename=/tmp/rec.jfr,settings=profile" bash dev/load.sh ${1:-6000} 0.2 2>&1 | grep -E "^ALL|^POST /api/articles/:slug/fav|Pause|errors"
docker exec cbox bash -c 'export PATH=/opt/jdk/bin:$PATH; jfr print --events jdk.ObjectAllocationSample /tmp/rec.jfr > /tmp/alloc.txt; python3 /repo/submissions/java-servlet-clickin/dev/alloc-report.py /tmp/alloc.txt'
