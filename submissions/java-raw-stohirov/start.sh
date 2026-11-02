#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT (optional tuning: see README).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
JDK=/usr/local/java-raw-stohirov/jdk
if [ -x "$JDK/bin/java" ]; then JAVA="$JDK/bin/java"; else JAVA="${JAVA_HOME:+$JAVA_HOME/bin/}java"; fi
HEAP="${JAVA_HEAP:-2g}"
CMD=("$JAVA" -Xms"$HEAP" -Xmx"$HEAP" -Xmn"${JAVA_YOUNG:-1g}" -Xss512k
  -XX:+UseParallelGC -XX:ParallelGCThreads="${GC_THREADS:-4}" -XX:+AlwaysPreTouch -XX:-UsePerfData -XX:-DontCompileHugeMethods --add-exports java.base/jdk.internal.misc=ALL-UNNAMED --enable-native-access=ALL-UNNAMED -Dconduit.native="$DIR/build/native/libbc.so"
  ${JAVA_OPTS:-} -cp "$DIR/build/classes" conduit.Main)
# SCHED_BATCH (no privileges needed, inherited by every thread): our threads wake constantly, and under the default
# policy each wakeup may preempt a busy Postgres backend. Batch threads get the same CPU share without cutting in.
if [ "${SCHED_BATCH:-1}" = 1 ] && command -v chrt >/dev/null && chrt --batch 0 true 2>/dev/null; then
  exec chrt --batch 0 "${CMD[@]}"
fi
exec "${CMD[@]}"
