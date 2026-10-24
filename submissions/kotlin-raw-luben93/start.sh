#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT (see README.md for optional knobs).
# CONDUIT_NATIVE=1 (development): runs the Kotlin/Native binary instead of the JVM build.
set -euo pipefail
cd "$(dirname "$0")"
if [ "${CONDUIT_NATIVE:-0}" = 1 ]; then exec build/bin/linuxX64/releaseExecutable/conduit.kexe; fi
if [ -x /opt/jdk/bin/java ]; then JAVA=/opt/jdk/bin/java; else JAVA="${JAVA_HOME:+$JAVA_HOME/bin/}java"; fi
# --enable-native-access: per-thread nice for the bcrypt workers via the FFM API.
exec "$JAVA" -Xms1g -Xmx1g -XX:+AlwaysPreTouch \
    --enable-native-access=ALL-UNNAMED \
    -cp "build/jvm/conduit.jar:build/jvm/lib/*" conduit.MainKt
