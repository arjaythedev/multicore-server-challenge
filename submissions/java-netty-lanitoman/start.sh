#!/usr/bin/env bash
# Runs the server in the foreground. Configured by DATABASE_URL, JWT_SECRET, HOST and PORT (SPEC.md).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${PREFIX:-/usr/local/conduit}"
JAVA="$PREFIX/jdk/bin/java"
[ -x "$JAVA" ] || JAVA="$(command -v java)"

# - A fixed heap with a large young generation: requests allocate short-lived objects only, so young collections
#   are rare and fast. The parallel collector with two threads: GC never competes with Postgres for every core.
# - Compact object headers: tens of thousands of idle keep-alive connections are mostly object headers.
# - The heap on transparent huge pages (fewer TLB misses), touched once at startup rather than during the run.
# - Netty may use Unsafe/direct memory and load its native epoll library without warnings; no leak detection.
exec "$JAVA" \
  -Xms2g -Xmx2g -Xmn1g \
  -XX:+UseParallelGC -XX:ParallelGCThreads=2 \
  -XX:+UseCompactObjectHeaders \
  -XX:+UseTransparentHugePages -XX:+AlwaysPreTouch \
  --enable-native-access=ALL-UNNAMED \
  --sun-misc-unsafe-memory-access=allow \
  --add-opens java.base/java.nio=ALL-UNNAMED \
  --add-opens java.base/jdk.internal.misc=ALL-UNNAMED \
  -Dio.netty.tryReflectionSetAccessible=true \
  -Dio.netty.leakDetection.level=disabled \
  ${JAVA_OPTS:-} \
  -jar "$HERE/target/conduit.jar"
