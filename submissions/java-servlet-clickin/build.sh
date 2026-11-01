#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
# install.sh's JDK wins over any JAVA_HOME already set (CI runners set their own)
JDK=/opt/jdk; [[ -x "$JDK/bin/javac" ]] || JDK="${JAVA_HOME:-}"
if [[ -x "$JDK/bin/javac" && -x "$JDK/bin/jar" ]]; then JAVAC="$JDK/bin/javac"; JAR="$JDK/bin/jar"; else JAVAC=javac; JAR=jar; fi
mkdir -p lib build/classes
JAR_PATH=lib/jakarta.servlet-api-6.1.0.jar
SERVLET_SHA256=8a31f465f3593bf2351531a5c952014eb839da96a605b5825b93dd54714c48c4
if [[ ! -f "$JAR_PATH" ]]; then
  temp=$(mktemp "${JAR_PATH}.XXXXXX")
  trap 'rm -f "$temp"' EXIT
  curl -fsSL https://repo1.maven.org/maven2/jakarta/servlet/jakarta.servlet-api/6.1.0/jakarta.servlet-api-6.1.0.jar -o "$temp"
  echo "$SERVLET_SHA256  $temp" | sha256sum -c -
  mv "$temp" "$JAR_PATH"
fi
echo "$SERVLET_SHA256  $JAR_PATH" | sha256sum -c -
find src -name '*.java' -print > build/sources.txt
"$JAVAC" --release 25 -cp "$JAR_PATH" -d build/classes @build/sources.txt
printf 'Manifest-Version: 1.0\nMain-Class: challenge.Main\nClass-Path: ../lib/jakarta.servlet-api-6.1.0.jar\n\n' > build/manifest.mf
"$JAR" cfm build/server.jar build/manifest.mf -C build/classes .
