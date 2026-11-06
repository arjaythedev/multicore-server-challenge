#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ $(uname -s) == Linux ]]; then
    export JAVA_HOME=/opt/conduit-temurin-25.0.5+8
    export PATH="$JAVA_HOME/bin:$PATH"
fi
exec build/install/conduit/bin/conduit
