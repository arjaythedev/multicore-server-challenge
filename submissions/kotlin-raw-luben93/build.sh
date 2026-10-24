#!/usr/bin/env bash
# Builds build/jvm/conduit.jar (+ build/jvm/lib/kotlin-stdlib) as a normal user. Idempotent.
# Needs only the JDK from install.sh; Gradle comes from ./gradlew (pinned, checksummed), Kotlin from Maven Central.
# CONDUIT_NATIVE=1 (development): also builds the Kotlin/Native binary (Gradle downloads Kotlin/Native itself).
set -euo pipefail
cd "$(dirname "$0")"
if [ -x /opt/jdk/bin/java ]; then export JAVA_HOME=/opt/jdk; fi
if [ "${CONDUIT_NATIVE:-0}" = 1 ]; then
  ./gradlew --no-daemon -q linkReleaseExecutableLinuxX64
  ls -l build/bin/linuxX64/releaseExecutable/conduit.kexe
else
  ./gradlew --no-daemon -q installJvm
  ls -l build/jvm/conduit.jar
fi
