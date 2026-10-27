#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT
# (optional tuning: see Settings in README.md).
set -euo pipefail
cd "$(dirname "$0")"
if [ -x /opt/jdk/bin/java ]; then JAVA=/opt/jdk/bin/java; else JAVA="${JAVA_HOME:+$JAVA_HOME/bin/}java"; fi
# G1 with a fixed 4 GB heap (a quarter of the box, like Postgres's shared_buffers), touched at startup (no heap
# resizing under load).
# --enable-native-access: lets Netty load its native epoll transport.
exec "$JAVA" -Xms4g -Xmx4g -XX:+AlwaysPreTouch --enable-native-access=ALL-UNNAMED \
  -cp "target/classes:target/lib/*" \
  dev.mccue.vertx.realworld.Main
