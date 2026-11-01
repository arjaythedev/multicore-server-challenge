#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT (and optionally DB_POOL_SIZE).
set -euo pipefail
cd "$(dirname "$0")"
if [ -x /opt/jdk/bin/java ]; then JAVA=/opt/jdk/bin/java; else JAVA="${JAVA_HOME:+$JAVA_HOME/bin/}java"; fi
exec "$JAVA" \
  --module-path target/server-distribution/lib \
  --add-modules dev.mccue.microhttp.realworld \
  --module dev.mccue.microhttp.realworld/dev.mccue.microhttp.realworld.Main
