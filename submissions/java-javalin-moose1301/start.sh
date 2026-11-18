#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT
# (optional tuning: see Settings in README.md). JAVA_OPTS_EXTRA adds JVM flags (profiling).
set -euo pipefail
cd "$(dirname "$0")"
if [ -x /opt/jdk/bin/java ]; then JAVA=/opt/jdk/bin/java; else JAVA="${JAVA_HOME:+$JAVA_HOME/bin/}java"; fi
# jdk.internal.misc is exported for bcrypt's unchecked off-heap S-box loads (see README.md).
# G1 with a fixed heap, touched at startup (no resizing under load). Tens of thousands of idle keep-alive
# connections live on the heap, so it is sized well above the working set.
exec "$JAVA" -Xms${HEAP:-3g} -Xmx${HEAP:-3g} -XX:+UseG1GC -XX:+AlwaysPreTouch -XX:+UseStringDeduplication \
  -XX:+PerfDisableSharedMem -Xss512k --add-exports java.base/jdk.internal.misc=ALL-UNNAMED ${JAVA_OPTS_EXTRA:-} \
  -cp "target/classes:target/lib/*" \
  dev.moose.conduit.ConduitApplication
