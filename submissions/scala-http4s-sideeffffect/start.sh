#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT.
# Optional: DB_READ_SESSIONS (default 32), DB_WRITE_SESSIONS (default 8), COMPUTE_THREADS and BCRYPT_THREADS (default
# half the cores each).
set -euo pipefail
cd "$(dirname "$0")"
if [ -x /opt/jdk-27/bin/java ]; then JAVA=/opt/jdk-27/bin/java
else JAVA="${JAVA_HOME:?no JDK in /opt/jdk-27 (run install.sh) and JAVA_HOME is not set}/bin/java"; fi
# Parallel GC: the best CPU per request and tail latency in a sweep of G1, Parallel, ZGC and Shenandoah (FINDINGS.md).
# Heap: 45% of RAM (about 7 GB of 16 GB), fixed and pre-touched. Postgres gets shared_buffers (25%), its backends and
#   the page cache; there is no swap, so the heap must not grow later. Every open connection costs Ember ~35 KB, so
#   7 GB leaves room for 100,000+ connections.
# Fiber tracing is off: it records a stack frame per IO step, which costs CPU on every request.
exec "$JAVA" \
  -XX:+UseParallelGC -XX:MaxRAMPercentage=45 -XX:InitialRAMPercentage=45 -XX:+AlwaysPreTouch -XX:-UsePerfData \
  -Dcats.effect.tracing.mode=none --sun-misc-unsafe-memory-access=allow \
  -cp "$(cat target/classpath.txt)" conduit.Main
