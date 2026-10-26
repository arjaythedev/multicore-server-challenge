#!/usr/bin/env bash
# Builds build/jvm/conduit.jar (+ build/jvm/lib/kotlin-stdlib) as a normal user. Idempotent.
# Needs the JDK, Gradle, and gcc installed by install.sh; Kotlin comes from Maven Central.
# The installJvm task also compiles native/ (the Openwall bcrypt core) with `cc -O3 -fPIC -shared` into
# build/jvm/libconduit-bcrypt.so; without a C compiler it warns and the server uses its pure-Kotlin bcrypt lanes.
# CONDUIT_NATIVE=1 (development): also builds the Kotlin/Native binary (Gradle downloads Kotlin/Native itself).
set -euo pipefail
cd "$(dirname "$0")"
if [ -x /opt/jdk/bin/java ]; then export JAVA_HOME=/opt/jdk; fi
if [ "${CONDUIT_NATIVE:-0}" = 1 ]; then
  gradle --no-daemon -q linkReleaseExecutableLinuxX64
  ls -l build/bin/linuxX64/releaseExecutable/conduit.kexe
else
  gradle --no-daemon -q installJvm
  ls -l build/jvm/conduit.jar
fi
