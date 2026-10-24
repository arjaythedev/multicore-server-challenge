#!/usr/bin/env bash
# Builds target/server-distribution/lib (the app jar and every dependency, run on the module path). Idempotent.
# Needs only a JDK; Maven comes from ./mvnw.
set -euo pipefail
cd "$(dirname "$0")"
# the JDK 27 from install.sh wins over any JAVA_HOME already set (CI runners set their own)
if [ -x /opt/jdk/bin/java ]; then export JAVA_HOME=/opt/jdk; fi
./mvnw -q -B -DskipTests package assembly:single
ls target/server-distribution/lib >/dev/null
