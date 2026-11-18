#!/usr/bin/env bash
# Builds build/install/conduit (start scripts + jars). Idempotent. Needs only a JDK 26; Gradle comes from ./gradlew.
# kiwiproc validates every SQL statement at compile time against the schema, using a throwaway embedded PostgreSQL
# that it starts itself (as this non-root user); the real database is not involved.
set -euo pipefail
cd "$(dirname "$0")"
# the JDK 26 from install.sh wins over any JAVA_HOME already set (CI runners set their own)
if [ -x /opt/jdk/bin/java ]; then export JAVA_HOME=/opt/jdk; fi
./gradlew --no-daemon -q installDist -Porg.gradle.java.installations.auto-download=false
ls -l build/install/conduit/lib/
