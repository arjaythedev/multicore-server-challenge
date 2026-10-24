#!/usr/bin/env bash
# Builds build/jvm/conduit.jar (+ build/jvm/lib/kotlin-stdlib) as a normal user. Idempotent.
# Needs only the JDK from install.sh; Gradle comes from ./gradlew (pinned, checksummed), Kotlin from Maven Central.
set -euo pipefail
cd "$(dirname "$0")"
if [ -x /opt/jdk/bin/java ]; then export JAVA_HOME=/opt/jdk; fi
./gradlew --no-daemon -q installJvm
ls -l build/jvm/conduit.jar
