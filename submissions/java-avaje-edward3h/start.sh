#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT.
# HikariCP pool of 10 connections per core. Default JVM flags for heap and GC: the JVM sizes them from the box.
# The JDK HTTP server closes idle keep-alive connections after 30 s and keeps at most 200 of them: raise both
# (idle interval in seconds, longer than Nginx's 60 s upstream keep-alive).
set -euo pipefail
cd "$(dirname "$0")"
export DB_POOL_SIZE="${DB_POOL_SIZE:-$(( 10 * $(nproc 2>/dev/null || sysctl -n hw.ncpu) ))}"
if [ -x /opt/jdk/bin/java ]; then JAVA=/opt/jdk/bin/java; else JAVA="$JAVA_HOME/bin/java"; fi   # install.sh's JDK 26 first
exec "$JAVA" -Dsun.net.httpserver.idleInterval=75 -Dsun.net.httpserver.maxIdleConnections=100000 -cp "build/install/conduit/lib/*" conduit.Main
