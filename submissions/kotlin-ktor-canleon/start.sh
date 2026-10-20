#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT; optional DB_POOL_SIZE (total
# Postgres connections, default two per core: 16 on the box). The Vert.x client pipelines, so a few connections serve
# all requests, and fewer Postgres processes compete with the app for the same cores. Measured: 8 connections were too
# few, 24 and 32 no better than 16.
set -euo pipefail
cd "$(dirname "$0")"
if [ -x /opt/jdk/bin/java ]; then JAVA=/opt/jdk/bin/java; else JAVA="$JAVA_HOME/bin/java"; fi   # install.sh's JDK 27 first
# G1 with a fixed 2 GB heap, touched at startup: no heap resizing under load (measured 2.5% less app CPU than the
# default, which starts at 8 MB). Leaves Postgres its share of the 16 GB.
# --enable-native-access: lets Netty load its native epoll transport (JNI is restricted since JDK 24).
exec "$JAVA" -Xms2g -Xmx2g -XX:+AlwaysPreTouch --enable-native-access=ALL-UNNAMED \
    -cp "target/conduit.jar:target/lib/*" conduit.MainKt
