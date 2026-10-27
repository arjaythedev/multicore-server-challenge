#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT (see README.md for optional knobs).
# CONDUIT_NATIVE=1 (development): runs the Kotlin/Native binary instead of the JVM build.
set -euo pipefail
cd "$(dirname "$0")"
if [ "${CONDUIT_NATIVE:-0}" = 1 ]; then exec build/bin/linuxX64/releaseExecutable/conduit.kexe; fi
if [ -x /opt/jdk/bin/java ]; then JAVA=/opt/jdk/bin/java; else JAVA="${JAVA_HOME:+$JAVA_HOME/bin/}java"; fi
# --enable-native-access: the FFM epoll HTTP loops and per-thread nice for the bcrypt workers.
# Measured cheaper per request (DESIGN.md): transparent huge pages for the heap (madvise, process-local), membarrier
# instead of a fence in every Java<->native thread-state transition, no hsperfdata file. G1 stays: ParallelGC's
# pauses failed p95 at saturation.
# Heap 3g (JAVA_HEAP overrides; 1g filled up in the 120k-user overload), 4m regions: no humongous Postgres buffers.
exec "$JAVA" -Xms${JAVA_HEAP:-3g} -Xmx${JAVA_HEAP:-3g} -XX:+AlwaysPreTouch -XX:G1HeapRegionSize=4m \
    -XX:+UseTransparentHugePages -XX:+UseSystemMemoryBarrier -XX:-UsePerfData \
    --enable-native-access=ALL-UNNAMED \
    -cp "build/jvm/conduit.jar:build/jvm/lib/*" conduit.MainKt
