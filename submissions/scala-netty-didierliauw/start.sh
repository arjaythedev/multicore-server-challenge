#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT.
set -euo pipefail
cd "$(dirname "$0")"
JAVA=/opt/scala-netty/jdk/bin/java; [ -x "$JAVA" ] || JAVA=java
# Generational ZGC: it collects beside the event loop instead of stopping it, and collects the old generation as it
# goes. Every open connection is a few Netty objects (~2 KB) kept for the whole run, and the challenge's search runs
# every probe and hold on one process: under the parallel collector each run's dead connections stayed in the old
# generation (about 120 MB a run) and its pauses grew with the connections (85-330 ms at 80,000 users); ZGC's heap
# stayed flat, and it passed 7 of 8 runs on one process where the parallel collector passed 5 of 8, at the same CPU
# per request. A fixed, pre-touched 2 GB of the box's 16: room for 100,000 connections and, under overload, every
# user's request waiting for Postgres (1 GB ran out at 128,000 users). Compact object headers shrink every object.
exec "$JAVA" \
  -XX:+UseZGC -Xms2g -Xmx2g \
  -XX:+AlwaysPreTouch -XX:+UseCompactObjectHeaders \
  -Dio.netty.leakDetection.level=disabled \
  --enable-native-access=ALL-UNNAMED --sun-misc-unsafe-memory-access=allow \
  -cp 'target/lib/*' conduit.Main
