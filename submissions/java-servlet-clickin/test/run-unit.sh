#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# install.sh's JDK wins over any JAVA_HOME already set (CI runners set their own)
JDK=/opt/jdk; [[ -x "$JDK/bin/javac" ]] || JDK="${JAVA_HOME:-}"
if [[ -x "$JDK/bin/javac" && -x "$JDK/bin/java" ]]; then JAVAC="$JDK/bin/javac"; JAVA="$JDK/bin/java"; else JAVAC=javac; JAVA=java; fi
mkdir -p build/test-classes
find src test -name '*.java' -print > build/test-sources.txt
"$JAVAC" --release 25 -cp lib/jakarta.servlet-api-6.1.0.jar -d build/test-classes @build/test-sources.txt
for test in challenge.JsonWriterTest challenge.JwtTest challenge.pg.QueryTest challenge.BCryptTest challenge.BcryptPoolTest challenge.http.PendingTest challenge.pg.UnitQueueTest challenge.pg.PgConnTest challenge.app.FormatsTest challenge.app.InputsTest challenge.app.RouteTest challenge.servlet.SegmentsTest challenge.servlet.ContainerTest challenge.servlet.ServletApiTest; do
  "$JAVA" --enable-native-access=ALL-UNNAMED -cp build/test-classes:lib/jakarta.servlet-api-6.1.0.jar "$test"
  printf '%s passed\n' "$test"
done
