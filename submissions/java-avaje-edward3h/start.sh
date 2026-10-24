#!/usr/bin/env bash
# Runs the server in the foreground. Config: DATABASE_URL, JWT_SECRET, HOST, PORT.
# HikariCP pool of 10 connections per core. Default JVM flags for heap and GC: the JVM sizes them from the box.
set -euo pipefail
cd "$(dirname "$0")"
export DB_POOL_SIZE="${DB_POOL_SIZE:-$(( 10 * $(nproc 2>/dev/null || sysctl -n hw.ncpu) ))}"
if [ -x /opt/jdk/bin/java ]; then JAVA=/opt/jdk/bin/java; else JAVA="$JAVA_HOME/bin/java"; fi   # install.sh's JDK 26 first
exec "$JAVA" -cp "build/install/conduit/lib/*" conduit.Main
