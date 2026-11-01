#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: installs a pinned JDK (Eclipse Temurin 25.0.4.1) from its official
# tarball, checked against its published SHA-256, into /usr/local/java-raw-stohirov/jdk. Nothing else: the server
# uses only the JDK (no Maven, no dependencies).
set -euo pipefail
PREFIX=/usr/local/java-raw-stohirov
JDK_URL="https://github.com/adoptium/temurin25-binaries/releases/download/jdk-25.0.4.1%2B1/OpenJDK25U-jdk_x64_linux_hotspot_25.0.4.1_1.tar.gz"
JDK_SHA256="dbb698396d478e7fa2b1e50f4103324b2a99b90569ee27c33f2261f9215cf41e"

if command -v apt-get >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get install -y -q ca-certificates curl tar gzip util-linux
fi
if [ -x "$PREFIX/jdk/bin/java" ] && "$PREFIX/jdk/bin/java" -version 2>&1 | grep -q '"25.0.4.1"'; then
  echo "JDK already installed"
else
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/jdk.tar.gz" "$JDK_URL"
  echo "$JDK_SHA256  $tmp/jdk.tar.gz" | sha256sum -c -
  rm -rf "$PREFIX/jdk"
  mkdir -p "$PREFIX/jdk"
  tar -xzf "$tmp/jdk.tar.gz" -C "$PREFIX/jdk" --strip-components=1
  rm -rf "$tmp"
fi
chmod -R a+rX "$PREFIX"
"$PREFIX/jdk/bin/java" -version
