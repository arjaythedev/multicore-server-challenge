#!/usr/bin/env bash
# Compiles the server with javac into build/classes and the bcrypt kernels with cc into build/native (no dependencies
# to download). Without a working C compiler the server still runs, on its Java kernels.
set -euo pipefail
cd "$(dirname "$0")"
JDK=/usr/local/java-raw-stohirov/jdk
if [ -x "$JDK/bin/javac" ]; then JAVAC="$JDK/bin/javac"; else JAVAC="${JAVA_HOME:+$JAVA_HOME/bin/}javac"; fi
rm -rf build/classes
mkdir -p build/classes
"$JAVAC" -encoding UTF-8 -proc:none --add-exports java.base/jdk.internal.misc=ALL-UNNAMED -d build/classes src/conduit/*.java
rm -rf build/native
mkdir -p build/native
if ! { cc -O2 -fPIC -c native/bc.c -o build/native/bc.o \
  && cc -c -x assembler-with-cpp native/bc_x86_64.S -o build/native/bc_x86_64.o \
  && cc -shared -o build/native/libbc.so build/native/bc.o build/native/bc_x86_64.o; }; then
  echo "build.sh: could not build native/, the server will use its Java bcrypt kernels" >&2
  rm -rf build/native
fi
