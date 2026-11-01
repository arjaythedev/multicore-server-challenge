#!/usr/bin/env bash
# Runs the server in the foreground. Configured by DATABASE_URL, JWT_SECRET, HOST and PORT (SPEC.md).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

PREFIX="${PREFIX:-/usr/local/java-netty-neeraj06152k}"

# 1. Locate Java runtime (prioritize the toolchain installed by install.sh in PREFIX)
if [ -x "$PREFIX/graalvm/bin/java" ]; then
  export JAVA_HOME="$PREFIX/graalvm"
elif [ -x "$PREFIX/jdk/bin/java" ]; then
  export JAVA_HOME="$PREFIX/jdk"
elif [ -x "/usr/local/conduit/graalvm/bin/java" ]; then
  export JAVA_HOME="/usr/local/conduit/graalvm"
elif [ -x "/usr/local/conduit/jdk/bin/java" ]; then
  export JAVA_HOME="/usr/local/conduit/jdk"
elif [ -x "/home/nrj/Java/graalvm-jdk-25/bin/java" ]; then
  export JAVA_HOME="/home/nrj/Java/graalvm-jdk-25"
elif [ -d "${HOME:-}/Java/graalvm-jdk-25" ] && [ -x "${HOME:-}/Java/graalvm-jdk-25/bin/java" ]; then
  export JAVA_HOME="${HOME}/Java/graalvm-jdk-25"
elif [ -x "/opt/graalvm/bin/java" ]; then
  export JAVA_HOME="/opt/graalvm"
elif [ -x "/opt/jdk/bin/java" ]; then
  export JAVA_HOME="/opt/jdk"
fi

JAVA=""
if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
  JAVA="$JAVA_HOME/bin/java"
elif [ -x "/usr/local/bin/java" ]; then
  JAVA="/usr/local/bin/java"
elif command -v java >/dev/null; then
  JAVA="$(command -v java)"
fi

if [ -z "$JAVA" ] || [ ! -x "$JAVA" ]; then
  echo "Error: Java runtime not found. Run install.sh first." >&2
  exit 1
fi

# Assert Java version 25
JAVA_VER="$("$JAVA" -version 2>&1 | awk -F '"' '/version/ {print $2}')"
case "$JAVA_VER" in
  25*)
    echo "Running with JDK 25: $JAVA ($JAVA_VER)"
    ;;
  *)
    echo "Error: Java 25 required, but found '$JAVA_VER' at $JAVA." >&2
    exit 1
    ;;
esac

JAR="$HERE/target/conduit.jar"
if [ ! -f "$JAR" ]; then
  echo "Error: $JAR not found. Run build.sh first." >&2
  exit 1
fi

# 2. Adaptive Memory Sizing
# Prevent Out-Of-Memory errors on lower-memory VMs (e.g. CI with 7GB RAM or dual-core laptops)
# while reserving optimal RAM for PostgreSQL 18 shared buffers & page cache on the 16GB benchmark box.
# NOTE: Never set -Xmn with G1GC; -Xmn disables dynamic young-gen sizing and overrides MaxGCPauseMillis!
MEM_TOTAL_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 16777216)
if [ "$MEM_TOTAL_KB" -ge 12582912 ]; then
  # 16GB box (or 20GB test laptop): 6GB fixed heap
  HEAP_FLAGS="-Xms6g -Xmx6g"
elif [ "$MEM_TOTAL_KB" -ge 6291456 ]; then
  # 7GB-8GB machine (e.g. GitHub Actions CI runner): 2GB heap
  HEAP_FLAGS="-Xms2g -Xmx2g"
else
  # Minimal memory environment: 1GB heap
  HEAP_FLAGS="-Xms1g -Xmx1g"
fi

# 3. Production JIT Runtime Flags:
# - G1GC with 20ms pause target & 45% IHOP
# - AlwaysPreTouch to eliminate page-fault latency during load measurement
# - Low-overhead direct off-heap Netty buffer allocation with 4 direct arenas
# - Unsafe & FFM native access enabled without warnings
CMD=("$JAVA" \
  ${HEAP_FLAGS} \
  -XX:+AlwaysPreTouch \
  -XX:+UseG1GC \
  -XX:MaxGCPauseMillis=20 \
  -XX:InitiatingHeapOccupancyPercent=45 \
  --enable-preview \
  --enable-native-access=ALL-UNNAMED \
  --sun-misc-unsafe-memory-access=allow \
  --add-opens java.base/java.nio=ALL-UNNAMED \
  --add-opens java.base/jdk.internal.misc=ALL-UNNAMED \
  -Dio.netty.allocator.type=pooled \
  -Dio.netty.allocator.numDirectArenas=4 \
  -Dio.netty.tryReflectionSetAccessible=true \
  -Dio.netty.leakDetection.level=disabled \
  ${JAVA_OPTS:-} \
  -jar "$JAR" "$@")

# Run under SCHED_BATCH so server wakeups do not preempt busy PostgreSQL backends
if [ "${SCHED_BATCH:-1}" = 1 ] && command -v chrt >/dev/null && chrt --batch 0 true 2>/dev/null; then
  exec chrt --batch 0 "${CMD[@]}"
fi
exec "${CMD[@]}"

