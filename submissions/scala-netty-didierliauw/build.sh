#!/usr/bin/env bash
# Builds the app as a normal user: sbt fetches the pinned dependencies, compiles, and copies the app jar and its
# runtime classpath into target/lib, which start.sh runs.
set -euo pipefail
cd "$(dirname "$0")"
OPT=/opt/scala-netty
if [ -x "$OPT/jdk/bin/java" ]; then export JAVA_HOME="$OPT/jdk" PATH="$OPT/jdk/bin:$PATH"; fi
SBT="$OPT/sbt/bin/sbt"; [ -x "$SBT" ] || SBT=sbt
"$SBT" -batch -no-colors -Dsbt.server.autostart=false -Dsbt.supershell=false stage
