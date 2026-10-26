#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: installs a pinned JDK (Eclipse Temurin 25) and Maven from their
# official tarballs, both checked against their published checksums.
#   JDK:   /usr/local/conduit/jdk   (https://adoptium.net)
#   Maven: /usr/local/conduit/maven (https://maven.apache.org)
set -euo pipefail

PREFIX="${PREFIX:-/usr/local/conduit}"
JDK_URL="https://github.com/adoptium/temurin25-binaries/releases/download/jdk-25.0.4.1%2B1/OpenJDK25U-jdk_x64_linux_hotspot_25.0.4.1_1.tar.gz"
JDK_SHA256="dbb698396d478e7fa2b1e50f4103324b2a99b90569ee27c33f2261f9215cf41e"
MAVEN_URL="https://archive.apache.org/dist/maven/maven-3/3.9.11/binaries/apache-maven-3.9.11-bin.tar.gz"
MAVEN_SHA512="bcfe4fe305c962ace56ac7b5fc7a08b87d5abd8b7e89027ab251069faebee516b0ded8961445d6d91ec1985dfe30f8153268843c89aa392733d1a3ec956c9978"

if [ "$(id -u)" = 0 ] && command -v apt-get >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get install -y -q ca-certificates curl tar gzip gcc libc6-dev   # gcc: build.sh compiles native/
fi

download() {  # url, checksum command, checksum, destination directory
  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/archive.tar.gz" "$1"
  echo "$3  $tmp/archive.tar.gz" | "$2" -c -
  rm -rf "$4"
  mkdir -p "$4"
  tar -xzf "$tmp/archive.tar.gz" -C "$4" --strip-components=1
  rm -rf "$tmp"
}

if [ -x "$PREFIX/jdk/bin/java" ] && "$PREFIX/jdk/bin/java" -version 2>&1 | grep -q '"25.0.4.1"'; then
  echo "JDK already installed"
else
  download "$JDK_URL" sha256sum "$JDK_SHA256" "$PREFIX/jdk"
fi
if [ -x "$PREFIX/maven/bin/mvn" ] && "$PREFIX/maven/bin/mvn" -v 2>/dev/null | grep -q "3.9.11"; then
  echo "Maven already installed"
else
  download "$MAVEN_URL" sha512sum "$MAVEN_SHA512" "$PREFIX/maven"
fi
"$PREFIX/jdk/bin/java" -version
JAVA_HOME="$PREFIX/jdk" "$PREFIX/maven/bin/mvn" -v | head -1
