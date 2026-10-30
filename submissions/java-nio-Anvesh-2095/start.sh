#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT.
# Tuning (optional): LOOPS (event-loop threads, default min(8, cores)), DB_READ (24) and DB_WRITE (4) Postgres
# connections, BCRYPT_THREADS (3), JAVA_OPTS (replaces the JVM flags below).
set -euo pipefail
cd "$(dirname "$0")"
if [ -x /opt/jdk/bin/java ]; then JAVA=/opt/jdk/bin/java; else JAVA="${JAVA_HOME:+$JAVA_HOME/bin/}java"; fi
# Fixed heap and generational ZGC (the only ZGC mode on JDK 23+) for short pauses.
JAVA_OPTS="${JAVA_OPTS:--Xms2g -Xmx2g -XX:+UseZGC -XX:+ExitOnOutOfMemoryError}"
# shellcheck disable=SC2086
exec "$JAVA" $JAVA_OPTS -jar build/conduit.jar
