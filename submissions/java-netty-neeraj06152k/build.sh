#!/usr/bin/env bash
# Builds target/conduit.jar as a normal user. Maven downloads pinned dependencies (pom.xml) on first build.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

PREFIX="${PREFIX:-/usr/local/java-netty-neeraj06152k}"

# 1. Locate Java 25 JDK
JAVA=""
if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
  JAVA="$JAVA_HOME/bin/java"
elif [ -x "$PREFIX/graalvm/bin/java" ]; then
  export JAVA_HOME="$PREFIX/graalvm"
  JAVA="$PREFIX/graalvm/bin/java"
elif [ -x "$PREFIX/jdk/bin/java" ]; then
  export JAVA_HOME="$PREFIX/jdk"
  JAVA="$PREFIX/jdk/bin/java"
elif [ -x "/usr/local/conduit/graalvm/bin/java" ]; then
  export JAVA_HOME="/usr/local/conduit/graalvm"
  JAVA="/usr/local/conduit/graalvm/bin/java"
elif [ -x "/usr/local/conduit/jdk/bin/java" ]; then
  export JAVA_HOME="/usr/local/conduit/jdk"
  JAVA="/usr/local/conduit/jdk/bin/java"
elif [ -x "/usr/local/bin/java" ]; then
  JAVA="/usr/local/bin/java"
elif command -v java >/dev/null; then
  JAVA="$(command -v java)"
elif [ -x "/opt/graalvm/bin/java" ]; then
  export JAVA_HOME="/opt/graalvm"
  JAVA="/opt/graalvm/bin/java"
elif [ -x "/opt/jdk/bin/java" ]; then
  export JAVA_HOME="/opt/jdk"
  JAVA="/opt/jdk/bin/java"
elif [ -x "/home/nrj/Java/graalvm-jdk-25/bin/java" ]; then
  export JAVA_HOME="/home/nrj/Java/graalvm-jdk-25"
  JAVA="/home/nrj/Java/graalvm-jdk-25/bin/java"
elif [ -d "${HOME:-}/Java/graalvm-jdk-25" ] && [ -x "${HOME:-}/Java/graalvm-jdk-25/bin/java" ]; then
  export JAVA_HOME="${HOME}/Java/graalvm-jdk-25"
  JAVA="${HOME}/Java/graalvm-jdk-25/bin/java"
fi

if [ -z "$JAVA" ] || [ ! -x "$JAVA" ]; then
  echo "Error: Java 25 JDK not found. Run install.sh as root first." >&2
  exit 1
fi

# Ensure bin is on PATH for child processes
if [ -n "${JAVA_HOME:-}" ] && [ -d "$JAVA_HOME/bin" ]; then
  export PATH="$JAVA_HOME/bin:${PATH}"
fi

# 2. Locate Apache Maven
MVN=""
if [ -x "$PREFIX/maven/bin/mvn" ]; then
  MVN="$PREFIX/maven/bin/mvn"
elif [ -x "/usr/local/conduit/maven/bin/mvn" ]; then
  MVN="/usr/local/conduit/maven/bin/mvn"
elif [ -x "/usr/local/bin/mvn" ]; then
  MVN="/usr/local/bin/mvn"
elif command -v mvn >/dev/null; then
  MVN="$(command -v mvn)"
elif [ -x "$HERE/mvnw" ]; then
  MVN="$HERE/mvnw"
fi

if [ -z "$MVN" ] || [ ! -x "$MVN" ]; then
  echo "Error: Apache Maven not found. Run install.sh as root first." >&2
  exit 1
fi

export MAVEN_OPTS="${MAVEN_OPTS:-} --sun-misc-unsafe-memory-access=allow"

echo "Building Conduit Uber-JAR with HotSpot JIT..."
"$MVN" -q -B -f "$HERE/pom.xml" -DskipTests clean package

JAR="$HERE/target/conduit.jar"
if [ ! -f "$JAR" ]; then
  echo "Error: Build completed but $JAR was not found." >&2
  exit 1
fi

ls -lh "$JAR"
echo "Build complete: $JAR"
