#!/usr/bin/env bash
# Builds as a normal user: compiles the app with sbt and writes its runtime classpath to target/classpath.txt,
# which start.sh runs. Dependencies (pinned in build.sbt) come from Maven Central.
set -euo pipefail
cd "$(dirname "$0")"
if [ -x /opt/jdk-25/bin/java ]; then export JAVA_HOME=/opt/jdk-25; fi
export PATH="$JAVA_HOME/bin:$PATH"
SBT=/opt/sbt/bin/sbt; [ -x "$SBT" ] || SBT=sbt
"$SBT" -batch -Dsbt.server.forcestart=false compile writeClasspath
