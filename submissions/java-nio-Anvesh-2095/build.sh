#!/usr/bin/env bash
# Builds build/conduit.jar with plain javac (no dependencies, no build tool). Idempotent.
set -euo pipefail
cd "$(dirname "$0")"
# install.sh's JDK wins over any JAVA_HOME already set (CI runners set their own)
if [ -x /opt/jdk/bin/javac ]; then JDK=/opt/jdk/bin/; elif [ -n "${JAVA_HOME:-}" ]; then JDK="$JAVA_HOME/bin/"; else JDK=""; fi
rm -rf build
mkdir -p build/classes
find src/main/java -name '*.java' > build/sources.txt
"${JDK}javac" --release 21 -encoding UTF-8 -Xlint:all,-serial -d build/classes @build/sources.txt
"${JDK}jar" --create --file build/conduit.jar --main-class conduit.Main -C build/classes .
ls -l build/conduit.jar
