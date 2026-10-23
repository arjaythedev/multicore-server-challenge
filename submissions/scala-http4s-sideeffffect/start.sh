#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT.
# Optional: DB_POOL_SIZE (default 4 per core), BCRYPT_THREADS (default half the cores).
set -euo pipefail
cd "$(dirname "$0")"
if [ -x /opt/jdk-25/bin/java ]; then JAVA=/opt/jdk-25/bin/java; else JAVA="$JAVA_HOME/bin/java"; fi
# G1 with a fixed, pre-touched 4 GB heap: the box has 16 GB, shared with Postgres (about 2.4 GB of data).
# Fiber tracing is off: it records a stack frame per IO step, which costs CPU on every request.
exec "$JAVA" \
  -XX:+UseG1GC -Xms4g -Xmx4g -XX:MaxGCPauseMillis=50 -XX:+AlwaysPreTouch -XX:-UsePerfData \
  -Dcats.effect.tracing.mode=none --sun-misc-unsafe-memory-access=allow \
  -cp "$(cat target/classpath.txt)" conduit.Main
