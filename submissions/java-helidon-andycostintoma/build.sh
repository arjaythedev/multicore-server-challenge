#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ $(uname -s) == Linux ]]; then
    export JAVA_HOME=/opt/conduit-temurin-25.0.5+8
    export PATH="$JAVA_HOME/bin:$PATH"
    tasks=(clean test installDist)
    if [[ ${RUN_INTEGRATION_TESTS:-0} == 1 ]]; then
        tasks=(clean check installDist)
    fi
    exec /opt/conduit-gradle-9.8.2/bin/gradle --no-daemon "${tasks[@]}"
fi
exec gradle --no-daemon clean check installDist
