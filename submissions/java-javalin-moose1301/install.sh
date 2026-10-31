#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: Eclipse Temurin JDK 25.0.5+8 (LTS, SHA-256 pinned) -> /opt/jdk.
# Maven 3.9.16 comes from the project's own ./mvnw wrapper at build time.
set -euo pipefail
apt-get update -q && apt-get install -y -q curl ca-certificates
URL="https://github.com/adoptium/temurin25-binaries/releases/download/jdk-25.0.5%2B8/OpenJDK25U-jdk_x64_linux_hotspot_25.0.5_8.tar.gz"
SHA="68982529869257d0ee6b824ec5aa270ff8b118bb438670da0b97ebdab178d7fb"
curl -fsSLo /tmp/jdk.tgz "$URL"
echo "$SHA  /tmp/jdk.tgz" | sha256sum -c -
rm -rf /opt/jdk && mkdir -p /opt/jdk && tar -C /opt/jdk --strip-components=1 -xzf /tmp/jdk.tgz && rm /tmp/jdk.tgz
chmod -R a+rX /opt/jdk
/opt/jdk/bin/java -version
