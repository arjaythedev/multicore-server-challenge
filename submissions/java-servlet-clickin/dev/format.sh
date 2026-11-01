#!/usr/bin/env bash
# Formats src and test with jfmt (Netflix/ja). Usage: bash dev/format.sh [--check]
# jfmt ships with a ja-enabled JDK: https://github.com/Netflix/ja#installation
set -euo pipefail
cd "$(dirname "$0")/.."
JFMT=$(command -v jfmt || true)
[[ -z "$JFMT" && -n "${JAVA_HOME:-}" && -x "$JAVA_HOME/bin/jfmt" ]] && JFMT="$JAVA_HOME/bin/jfmt"
[[ -n "$JFMT" ]] || { echo 'jfmt not found: select a ja-enabled JDK' >&2; exit 1; }
find src test -name '*.java' -print0 | xargs -0 "$JFMT" "$@" --release 25 -cp lib/jakarta.servlet-api-6.1.0.jar --source-path src:test
