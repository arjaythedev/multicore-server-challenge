#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT (see README.md for optional knobs).
# CONDUIT_NATIVE=1 (development): runs the Kotlin/Native binary instead of the JVM build.
set -euo pipefail
cd "$(dirname "$0")"
if [ "${CONDUIT_NATIVE:-0}" = 1 ]; then exec build/bin/linuxX64/releaseExecutable/conduit.kexe; fi
if [ -x /opt/jdk/bin/java ]; then JAVA=/opt/jdk/bin/java; else JAVA="${JAVA_HOME:+$JAVA_HOME/bin/}java"; fi
# This submission is the production-style stack: Netty's HTTP/1.1 server + the Vert.x Postgres client, by default.
# Set to empty to compare: HTTP_IO= (our epoll HTTP engine), DB_DRIVER=own (our Postgres wire client).
export HTTP_IO="${HTTP_IO-netty-http}" DB_DRIVER="${DB_DRIVER-vertx}"
# --enable-native-access: the FFM epoll HTTP loops and per-thread nice for the bcrypt workers.
# Measured cheaper per request (DESIGN.md): transparent huge pages for the heap (madvise, process-local), membarrier
# instead of a fence in every Java<->native thread-state transition, no hsperfdata file. G1 stays (lab, 120k users,
# 2026-10-28): ParallelGC p95/p99 105/209 ms vs 67/102; ZGC and Shenandoah cost ~2 us more app CPU per request for
# 1-3 ms of p99.
# Heap 3g (JAVA_HEAP overrides; 1g filled up in the 120k-user overload), 4m regions: no humongous Postgres buffers.
# Lab experiments: JAVA_GC=parallel|z|shenandoah (default g1); JAVA_OPTS_EXTRA=extra JVM flags, comma-separated.
case "${JAVA_GC:-g1}" in
  parallel) GC=(-XX:+UseParallelGC) ;;
  z) GC=(-XX:+UseZGC) ;;
  shenandoah) GC=(-XX:+UseShenandoahGC -XX:ShenandoahGCMode=generational) ;;
  *) GC=(-XX:+UseG1GC -XX:G1HeapRegionSize=4m) ;;
esac
IFS=, read -ra EXTRA <<<"${JAVA_OPTS_EXTRA:-}"
# HTTP_IO=netty / netty-http, or DB_DRIVER=vertx (Vert.x runs on Netty too): Netty's direct-buffer fast paths (no
# Cleaner, Unsafe copies) need the first three on JDK 24+; then the usual Netty server settings: the pooled allocator
# (4.1's default; NETTY_ALLOCATOR=adaptive, 4.2's default, measured equal), no leak detection, no bounds/refcount
# checks on every buffer access.
NETTY=()
case "${HTTP_IO:-}${DB_DRIVER:+-db-$DB_DRIVER}" in
  netty*|*-db-vertx*) NETTY=(--add-opens java.base/java.nio=ALL-UNNAMED --add-opens java.base/jdk.internal.misc=ALL-UNNAMED
                 -Dio.netty.tryReflectionSetAccessible=true "-Dio.netty.allocator.type=${NETTY_ALLOCATOR:-pooled}"
                 -Dio.netty.leakDetection.level=disabled -Dio.netty.buffer.checkBounds=false
                 -Dio.netty.buffer.checkAccessible=false)
          if "$JAVA" --sun-misc-unsafe-memory-access=allow -version > /dev/null 2>&1; then
            NETTY+=(--sun-misc-unsafe-memory-access=allow)
          fi ;;
esac
exec "$JAVA" -Xms${JAVA_HEAP:-3g} -Xmx${JAVA_HEAP:-3g} -XX:+AlwaysPreTouch "${GC[@]}" \
    -XX:+UseTransparentHugePages -XX:+UseSystemMemoryBarrier -XX:-UsePerfData \
    --enable-native-access=ALL-UNNAMED "${NETTY[@]}" "${EXTRA[@]}" \
    -cp "build/jvm/conduit.jar:build/jvm/lib/*" conduit.MainKt
