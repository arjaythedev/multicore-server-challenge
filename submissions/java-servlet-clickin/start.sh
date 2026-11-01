#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
# install.sh's JDK wins over any JAVA_HOME already set (CI runners set their own)
if [[ -x /opt/jdk/bin/java ]]; then JAVA=/opt/jdk/bin/java; elif [[ -x "${JAVA_HOME:-}/bin/java" ]]; then JAVA="$JAVA_HOME/bin/java"; else JAVA=java; fi
exec "$JAVA" -XX:+UseParallelGC -Xms2g -Xmx2g -Xmn768m -XX:+AlwaysPreTouch -Xlog:gc*:file=/tmp/conduit-gc.log:time,uptime:filecount=2,filesize=20m --enable-native-access=ALL-UNNAMED ${JAVA_OPTS:-} -cp 'build/server.jar:lib/jakarta.servlet-api-6.1.0.jar' challenge.Main
