#!/usr/bin/env bash
# Runs test/run.sh inside the local Linux container (see Dockerfile). Usage: bash dev/conformance.sh
set -euo pipefail
docker exec cbox bash -c 'cd /repo && export PATH=/opt/jdk/bin:$PATH PGHOST=127.0.0.1 PGUSER=postgres PGPASSWORD=postgres && bash test/run.sh submissions/java-servlet-clickin'
