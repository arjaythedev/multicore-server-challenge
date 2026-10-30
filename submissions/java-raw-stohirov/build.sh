#!/usr/bin/env bash
# Compiles the server with javac into build/classes (no dependencies to download).
set -euo pipefail
cd "$(dirname "$0")"
JDK=/usr/local/java-raw-stohirov/jdk
if [ -x "$JDK/bin/javac" ]; then JAVAC="$JDK/bin/javac"; else JAVAC="${JAVA_HOME:+$JAVA_HOME/bin/}javac"; fi
rm -rf build/classes
mkdir -p build/classes
"$JAVAC" -encoding UTF-8 -proc:none -d build/classes src/conduit/*.java
