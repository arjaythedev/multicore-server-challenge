#!/usr/bin/env bash
# Unit checks (bcrypt vectors and every lane width, JWT, timestamps, JSON) with the same JDK as the server.
set -euo pipefail
cd "$(dirname "$0")/.."
JDK=/usr/local/java-raw-stohirov/jdk
if [ -x "$JDK/bin/javac" ]; then BIN="$JDK/bin/"; else BIN="${JAVA_HOME:+$JAVA_HOME/bin/}"; fi
rm -rf build/test && mkdir -p build/test
"${BIN}javac" -encoding UTF-8 -proc:none -d build/test src/conduit/*.java test/conduit/*.java
"${BIN}java" -XX:-DontCompileHugeMethods -cp build/test conduit.SelfTest
