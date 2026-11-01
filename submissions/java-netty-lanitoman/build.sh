#!/usr/bin/env bash
# Builds target/conduit.jar as a normal user. Maven downloads the pinned dependencies (pom.xml) on the first build.
# Then compiles bcrypt's inner loop (native/bcrypt_lanes.c) into target/libconduit-bcrypt.so with the system C
# compiler; without one the server computes bcrypt in Java (slower, same results).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${PREFIX:-/usr/local/conduit}"
if [ -x "$PREFIX/jdk/bin/java" ]; then export JAVA_HOME="$PREFIX/jdk"; fi
MVN="$PREFIX/maven/bin/mvn"
[ -x "$MVN" ] || MVN="$(command -v mvn)"
# Maven's own libraries use sun.misc.Unsafe; this only silences the JDK's warning about it
export MAVEN_OPTS="${MAVEN_OPTS:-} --sun-misc-unsafe-memory-access=allow"
"$MVN" -q -B -f "$HERE/pom.xml" -DskipTests package
ls -l "$HERE/target/conduit.jar"

# -O3: the kernel's lane loops must be fully unrolled. No -march: the benchmark box's CPU model is unknown.
if command -v cc >/dev/null; then
  cc -O3 -fPIC -shared -o "$HERE/target/libconduit-bcrypt.so" "$HERE/native/bcrypt_lanes.c"
  ls -l "$HERE/target/libconduit-bcrypt.so"
else
  echo "warning: no C compiler; bcrypt will run in Java" >&2
fi
